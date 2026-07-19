-- 文件事务的快照校验、补偿回滚、实例隔离与撤回测试
-- 运行：nvim --headless --clean -l tests/test_fs_transaction.lua

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.runtimepath:prepend(repo)

local fs = require('vv-utils.fs')

local passed = 0
local failed = 0

local function test(name, fn)
  local ok, error = pcall(fn)
  if ok then
    passed = passed + 1
    print('[PASS] ' .. name)
  else
    failed = failed + 1
    print('[FAIL] ' .. name .. ': ' .. tostring(error))
  end
end

local function assert_eq(actual, expected)
  assert(actual == expected, string.format('expected %q, got %q', tostring(expected), tostring(actual)))
end

local function memory_transaction(files, write)
  return fs.new_transaction({
    read = function(path) return assert(files[path], 'missing ' .. path) end,
    write = write or function(path, content) files[path] = content end,
    check_modified_buffers = false,
  })
end

test('实例状态隔离且成功事务可撤回', function()
  local files = { a = 'old-a', b = 'old-b' }
  local first = memory_transaction(files)
  local second = memory_transaction(files)

  local ok, error = first:apply({
    { path = 'a', old = 'old-a', new = 'new-a' },
    { path = 'b', old = 'old-b', new = 'new-b' },
  })
  assert(ok, error)
  assert(first:can_undo())
  assert(not second:can_undo())

  local undo_ok, undo_error, count = first:undo()
  assert(undo_ok, undo_error)
  assert_eq(count, 2)
  assert_eq(files.a, 'old-a')
  assert_eq(files.b, 'old-b')
end)

test('写入已生效后报错仍回滚全部文件', function()
  local files = { a = 'old-a', b = 'old-b' }
  local transaction = memory_transaction(files, function(path, content)
    files[path] = content
    if path == 'b' and content == 'new-b' then error('error after write') end
  end)

  local ok = transaction:apply({
    { path = 'a', old = 'old-a', new = 'new-a' },
    { path = 'b', old = 'old-b', new = 'new-b' },
  })
  assert_eq(ok, false)
  assert_eq(files.a, 'old-a')
  assert_eq(files.b, 'old-b')
end)

test('逐文件重验快照且不覆盖并发外部修改', function()
  local files = { a = 'old-a', b = 'old-b' }
  local transaction = memory_transaction(files, function(path, content)
    files[path] = content
    if path == 'a' and content == 'new-a' then files.b = 'external-edit' end
  end)

  local ok = transaction:apply({
    { path = 'a', old = 'old-a', new = 'new-a' },
    { path = 'b', old = 'old-b', new = 'new-b' },
  })
  assert_eq(ok, false)
  assert_eq(files.a, 'old-a')
  assert_eq(files.b, 'external-edit')
end)

test('撤回预检冲突时零写入并保留撤回记录', function()
  local files = { a = 'old-a', b = 'old-b' }
  local writes = 0
  local transaction = memory_transaction(files, function(path, content)
    writes = writes + 1
    files[path] = content
  end)

  assert(transaction:apply({
    { path = 'a', old = 'old-a', new = 'new-a' },
    { path = 'b', old = 'old-b', new = 'new-b' },
  }))
  files.b = 'external-edit'
  writes = 0

  assert_eq(transaction:undo(), false)
  assert_eq(writes, 0)
  assert(transaction:can_undo())
  assert_eq(files.a, 'new-a')
  assert_eq(files.b, 'external-edit')
end)

test('撤回中途失败时恢复事务后状态并允许重试', function()
  local files = { a = 'old-a', b = 'old-b' }
  local fail_undo = false
  local transaction = memory_transaction(files, function(path, content)
    files[path] = content
    if fail_undo and path == 'b' and content == 'old-b' then error('undo failure after write') end
  end)

  assert(transaction:apply({
    { path = 'a', old = 'old-a', new = 'new-a' },
    { path = 'b', old = 'old-b', new = 'new-b' },
  }))
  fail_undo = true
  assert_eq(transaction:undo(), false)
  assert_eq(files.a, 'new-a')
  assert_eq(files.b, 'new-b')

  fail_undo = false
  assert(transaction:undo())
  assert_eq(files.a, 'old-a')
  assert_eq(files.b, 'old-b')
end)

test('新的成功事务覆盖上一层撤回记录', function()
  local files = { a = 'old' }
  local transaction = memory_transaction(files)

  assert(transaction:apply({ { path = 'a', old = 'old', new = 'first' } }))
  assert(transaction:apply({ { path = 'a', old = 'first', new = 'second' } }))
  assert(transaction:undo())
  assert_eq(files.a, 'first')
  assert(not transaction:can_undo())
end)

test('补偿回滚不完整后锁定当前实例', function()
  local files = { a = 'old-a', b = 'old-b' }
  local rollback_started = false
  local transaction = memory_transaction(files, function(path, content)
    if path == 'b' and content == 'new-b' then
      files[path] = content
      rollback_started = true
      error('apply failure after write')
    end
    if rollback_started and path == 'b' and content == 'old-b' then
      error('rollback failure')
    end
    files[path] = content
  end)

  local ok, error = transaction:apply({
    { path = 'a', old = 'old-a', new = 'new-a' },
    { path = 'b', old = 'old-b', new = 'new-b' },
  })
  assert_eq(ok, false)
  assert(error:find('rollback failed', 1, true), error)
  assert_eq(files.a, 'old-a')
  assert_eq(files.b, 'new-b')

  local retry_ok, retry_error = transaction:apply({
    { path = 'a', old = 'old-a', new = 'next-a' },
  })
  assert_eq(retry_ok, false)
  assert(retry_error:find('rollback is incomplete', 1, true), retry_error)
end)

test('未保存 buffer 阻止默认文件事务', function()
  local path = vim.fn.tempname()
  fs.write_all(path, 'disk\n')

  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'unsaved' })
  vim.bo[buf].modified = true

  local transaction = fs.new_transaction()
  local ok = transaction:apply({
    { path = path, old = 'disk\n', new = 'new\n' },
  })
  assert_eq(ok, false)
  assert_eq(fs.read_all(path), 'disk\n')

  vim.api.nvim_buf_delete(buf, { force = true })
  vim.uv.fs_unlink(path)
end)

print(string.format('总计: %d 通过, %d 失败', passed, failed))
if failed > 0 then vim.cmd('cquit 1') end
