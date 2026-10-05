-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  repo = vim.fn.fnamemodify((vim.env.VV_TEST_REPO .. '/tests/test_fs_transaction.lua'), ':p:h:h')
  vim.opt.runtimepath:prepend(repo)
  fs = require('vv-utils.fs')
  function assert_eq(actual, expected)
    assert(actual == expected, string.format('期望 %q，实际 %q', tostring(expected), tostring(actual)))
  end
  function memory_transaction(files, write)
    return fs.new_transaction({
      read = function(path) return assert(files[path], 'missing ' .. path) end,
      write = write or function(path, content) files[path] = content end,
      check_modified_buffers = false,
    })
  end
end)

T["实例状态隔离且成功事务可撤回"] = function()
  child.lua_func(function()
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
end

T["写入已生效后报错仍回滚全部文件"] = function()
  child.lua_func(function()
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
end

T["逐文件重验快照且不覆盖并发外部修改"] = function()
  child.lua_func(function()
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
end

T["撤回预检冲突时零写入并保留撤回记录"] = function()
  child.lua_func(function()
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
end

T["撤回中途失败时恢复事务后状态并允许重试"] = function()
  child.lua_func(function()
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
end

T["撤回写入前失败不会锁定事务且允许重试"] = function()
  child.lua_func(function()
    local files = { a = 'old-a' }
      local fail_before_write = false
      local transaction = memory_transaction(files, function(path, content)
        if fail_before_write and content == 'old-a' then error('undo write failed before touching file') end
        files[path] = content
      end)

      assert(transaction:apply({ { path = 'a', old = 'old-a', new = 'new-a' } }))
      fail_before_write = true

      local ok, error, _, touched = transaction:undo()
      assert_eq(ok, false)
      assert(error:find('undo write failed before touching file', 1, true), error)
      assert_eq(touched, nil)
      assert_eq(files.a, 'new-a')
      assert(not transaction:is_locked())
      assert(transaction:can_undo())

      fail_before_write = false
      assert(transaction:undo())
      assert_eq(files.a, 'old-a')
  end)
end

T["新的成功事务覆盖上一层撤回记录"] = function()
  child.lua_func(function()
    local files = { a = 'old' }
      local transaction = memory_transaction(files)

      assert(transaction:apply({ { path = 'a', old = 'old', new = 'first' } }))
      assert(transaction:apply({ { path = 'a', old = 'first', new = 'second' } }))
      assert(transaction:undo())
      assert_eq(files.a, 'first')
      assert(not transaction:can_undo())
  end)
end

T["补偿回滚不完整后锁定当前实例"] = function()
  child.lua_func(function()
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
end

T["未保存 buffer 阻止默认文件事务"] = function()
  child.lua_func(function()
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
end

return T
