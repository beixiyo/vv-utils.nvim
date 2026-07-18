-- 通用输入历史的内存与真实持久化测试
--
-- 运行方式：nvim --headless --clean -l tests/test_history.lua

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.runtimepath:prepend(repo)

local History = require('vv-utils.history')

local root = vim.fs.joinpath('/tmp', 'vv-utils-history-test-' .. vim.uv.os_getpid())
local path = vim.fs.joinpath(root, 'history.json')

local function cleanup()
  vim.fn.delete(root, 'rf')
end

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error(string.format('%s: expected %q, got %q', message, expected, actual))
  end
end

cleanup()

assert(not pcall(History.new, { name = '..' }), 'history name must not escape the state subdirectory')

local memory_path = vim.fs.joinpath(root, 'memory.json')
local memory = History.new({ name = 'memory-test', max_entries = 3, path = memory_path })
local compatible_path = History.new({ name = 'vv-replace' }).path
assert_eq(compatible_path, vim.fs.joinpath(vim.fn.stdpath('state'), 'vv-replace', 'history.json'),
  'default path preserves the existing vv-replace history location')
memory:record('search', 'first')
memory:record('search', 'second')
assert_eq(memory:previous('search', 'draft'), 'second', 'previous returns latest record')
assert_eq(memory:previous('search', 'second'), 'first', 'previous walks to older record')
assert_eq(memory:next('search', 'first'), 'second', 'next walks to newer record')
assert_eq(memory:next('search', 'second'), 'draft', 'next restores draft after latest record')

memory:record('replace', '$100')
assert_eq(memory:previous('replace', ''), '$100', 'fields keep independent history')

memory:record('search', '')
memory:record('search', 'third')
memory:record('search', 'first')
memory:record('search', 'fourth')
local memory_snapshot = memory:snapshot()
assert_eq(#memory_snapshot.search, 3, 'max_entries trims old records')
assert_eq(memory_snapshot.search[1], 'third', 'dedupe moves repeated values to latest position')
assert_eq(memory_snapshot.search[2], 'first', 'repeated value remains once')
assert_eq(memory_snapshot.search[3], 'fourth', 'latest value stays last')
assert(vim.uv.fs_stat(memory_path) == nil,
  'session-only history must not create a file')

local persisted = History.new({
  name = 'persist-test',
  max_entries = 3,
  persist = true,
  path = path,
})
assert_eq(persisted:record_many({
  { field = 'search', value = 'price' },
  { field = 'replace', value = '$100' },
}), 2, 'record_many returns changed record count')

-- 模拟另一个 Neovim 在当前实例旧快照之后写入磁盘记录
vim.fn.writefile({ vim.json.encode({
  version = 1,
  fields = {
    search = { 'price', 'external-new' },
    replace = { '$100' },
  },
}) }, path, 'b')
assert(persisted:record('search', 'local-new'), 'new local record should be accepted')

local stat = assert(vim.uv.fs_stat(path))
assert_eq(stat.mode % 512, 384, 'history file permissions are 0600')
local dir_stat = assert(vim.uv.fs_stat(root))
assert_eq(dir_stat.mode % 512, 448, 'history directory permissions are 0700')

-- 合并到磁盘的外部记录应立即进入当前实例，不必等到下次启动
assert_eq(persisted:previous('search', ''), 'local-new', 'current instance sees local record')
assert_eq(persisted:previous('search', 'local-new'), 'external-new', 'current instance sees merged external record')
assert_eq(persisted:previous('search', 'external-new'), 'price', 'current instance keeps older record')

local reloaded = History.new({
  name = 'persist-test',
  max_entries = 3,
  persist = true,
  path = path,
})
assert_eq(reloaded:previous('search', ''), 'local-new', 'latest record reloads from disk')
assert_eq(reloaded:previous('search', 'local-new'), 'external-new', 'external record survives merge')
assert_eq(reloaded:previous('search', 'external-new'), 'price', 'older record survives reload')
assert_eq(reloaded:previous('replace', ''), '$100', 'another field survives reload')

local entries = vim.fn.readdir(root)
assert_eq(#entries, 1, 'atomic write leaves no temporary file')
assert_eq(entries[1], 'history.json', 'only final history file remains')

cleanup()
print('PASS: vv-utils history memory and persistence behavior')
