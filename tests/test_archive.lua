local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local archive = require('vv-utils.archive')

local passed = 0
local failed = 0
local skipped = 0
local SKIP = {}

local function skip(reason)
  SKIP.reason = reason
  error(SKIP, 0)
end

local function test(name, fn)
  local ok, error_message = pcall(fn)
  if ok then
    passed = passed + 1
    print('  通过: ' .. name)
  elseif error_message == SKIP then
    skipped = skipped + 1
    print('  跳过: ' .. name .. ' — ' .. SKIP.reason)
  else
    failed = failed + 1
    print('  失败: ' .. name .. ' — ' .. tostring(error_message))
  end
end

local function assert_equal(actual, expected)
  assert(vim.deep_equal(actual, expected), vim.inspect({ actual = actual, expected = expected }))
end

local function await(invoke)
  local result
  invoke(function(value)
    result = value
  end)
  assert(vim.wait(5000, function() return result ~= nil end), '等待回调超时')
  return result
end

local function temp_dir()
  local path = vim.fn.tempname()
  assert(vim.fn.mkdir(path, 'p') == 1)
  return path
end

print('vv-utils.archive')

test('能够选择 Windows 的 tar.exe 候选命令', function()
  local original = vim.fn.executable
  vim.fn.executable = function(command) return command == 'tar.exe' and 1 or 0 end
  local ok, result = pcall(archive.resolve, { 'tar.exe', 'bsdtar.exe' })
  vim.fn.executable = original
  assert(ok, result)
  assert_equal(result, 'tar.exe')
end)

test('接受正常的相对归档成员路径', function()
  assert(archive.validate({ './', './dict/us.json', 'manifest.json' }))
end)

for _, case in ipairs({
  { '/etc/passwd', 'absolute_path' },
  { 'C:/Windows/system.ini', 'drive_path' },
  { '../escape', 'parent_traversal' },
  { 'dict/../../escape', 'parent_traversal' },
  { 'dict/file.txt:stream', 'alternate_data_stream' },
}) do
  test('拒绝危险路径类型 ' .. case[2], function()
    local ok, unsafe = archive.validate({ case[1] })
    assert(not ok)
    assert_equal(unsafe, { entry = case[1], reason = case[2] })
  end)
end

test('列出并解压包含 UTF-8 内容的真实 tar.gz', function()
  if vim.fn.executable('tar') ~= 1 then skip('当前环境没有 tar') end

  local root = temp_dir()
  local source = vim.fs.joinpath(root, 'source')
  local destination = vim.fs.joinpath(root, 'destination')
  local archive_path = vim.fs.joinpath(root, 'fixture.tar.gz')
  vim.fn.mkdir(vim.fs.joinpath(source, 'dict'), 'p')
  vim.fn.mkdir(destination, 'p')
  vim.fn.writefile({ '{"user":"n. 用户"}' }, vim.fs.joinpath(source, 'dict', 'us.json'))
  vim.fn.writefile({ '{"version":"1.0.0"}' }, vim.fs.joinpath(source, 'manifest.json'))

  local created = vim.system({ 'tar', '-czf', archive_path, '-C', source, '.' }, { text = true }):wait()
  assert_equal(created.code, 0)

  local listed = await(function(done)
    archive.list({ archive = archive_path }, done)
  end)
  assert(listed.ok, listed.message)
  assert(vim.tbl_contains(listed.entries, './dict/us.json'))

  local extracted = await(function(done)
    archive.extract({ archive = archive_path, destination = destination }, done)
  end)
  assert(extracted.ok, extracted.message)
  assert_equal(vim.fn.readfile(vim.fs.joinpath(destination, 'dict', 'us.json')), { '{"user":"n. 用户"}' })
end)

test('拒绝解压到非空目标目录', function()
  local destination = temp_dir()
  vim.fn.writefile({ 'keep' }, vim.fs.joinpath(destination, 'existing.txt'))
  local result = await(function(done)
    archive.extract({ archive = '/unused.tar.gz', destination = destination }, done)
  end)
  assert_equal(result.code, 'destination_not_empty')
end)

test('归档不存在时返回明确错误', function()
  local returned = false
  local result = await(function(done)
    archive.list({ archive = vim.fn.tempname() }, function(value)
      assert(returned, '预检错误不得在 list 返回前同步重入调用方')
      done(value)
    end)
    returned = true
  end)
  assert_equal(result.code, 'archive_not_found')
end)

test('取消能够压制尚未投递的预检错误', function()
  local called = false
  local cancel = archive.list({ archive = vim.fn.tempname() }, function()
    called = true
  end)
  cancel()
  local drained = false
  vim.schedule(function() drained = true end)
  assert(vim.wait(100, function() return drained end, 1), '主循环队列未完成排空')
  assert(not called, '取消后不得投递已经排队的预检错误')
end)

print(('\n%d 通过，%d 失败，%d 跳过'):format(passed, failed, skipped))
if failed > 0 then vim.cmd.cquit() end
