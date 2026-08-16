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
    error(string.format('%s：期望 %q，实际 %q', message, expected, actual))
  end
end

cleanup()

assert(not pcall(History.new, { name = '..' }), '历史名称不得逃逸状态子目录')

local memory_path = vim.fs.joinpath(root, 'memory.json')
local memory = History.new({ name = 'memory-test', max_entries = 3, path = memory_path })
local compatible_path = History.new({ name = 'vv-replace' }).path
assert_eq(compatible_path, vim.fs.joinpath(vim.fn.stdpath('state'), 'vv-replace', 'history.json'),
  '默认路径应保持既有 vv-replace 历史位置')
memory:record('search', 'first')
memory:record('search', 'second')
assert_eq(memory:previous('search', 'draft'), 'second', 'previous 应返回最新记录')
assert_eq(memory:previous('search', 'second'), 'first', 'previous 应移动到更早记录')
assert_eq(memory:next('search', 'first'), 'second', 'next 应移动到更新记录')
assert_eq(memory:next('search', 'second'), 'draft', '越过最新记录后 next 应恢复草稿')

memory:record('replace', '$100')
assert_eq(memory:previous('replace', ''), '$100', '不同字段应保持独立历史')

memory:record('search', '')
memory:record('search', 'third')
memory:record('search', 'first')
memory:record('search', 'fourth')
local memory_snapshot = memory:snapshot()
assert_eq(#memory_snapshot.search, 3, 'max_entries 应裁剪旧记录')
assert_eq(memory_snapshot.search[1], 'third', '去重应把重复值移动到最新位置')
assert_eq(memory_snapshot.search[2], 'first', '重复值应只保留一次')
assert_eq(memory_snapshot.search[3], 'fourth', '最新值应位于末尾')
assert(vim.uv.fs_stat(memory_path) == nil,
  '仅会话历史不得创建文件')

local persisted = History.new({
  name = 'persist-test',
  max_entries = 3,
  persist = true,
  path = path,
})
assert_eq(persisted:record_many({
  { field = 'search', value = 'price' },
  { field = 'replace', value = '$100' },
}), 2, 'record_many 应返回发生变化的记录数')

-- 模拟另一个 Neovim 在当前实例旧快照之后写入磁盘记录
vim.fn.writefile({ vim.json.encode({
  version = 1,
  fields = {
    search = { 'price', 'external-new' },
    replace = { '$100' },
  },
}) }, path, 'b')
assert(persisted:record('search', 'local-new'), '应接受新的本地记录')

local stat = assert(vim.uv.fs_stat(path))
assert_eq(stat.mode % 512, 384, '历史文件权限应为 0600')
local dir_stat = assert(vim.uv.fs_stat(root))
assert_eq(dir_stat.mode % 512, 448, '历史目录权限应为 0700')

-- 合并到磁盘的外部记录应立即进入当前实例，不必等到下次启动
assert_eq(persisted:previous('search', ''), 'local-new', '当前实例应看到本地记录')
assert_eq(persisted:previous('search', 'local-new'), 'external-new', '当前实例应看到合并后的外部记录')
assert_eq(persisted:previous('search', 'external-new'), 'price', '当前实例应保留更早记录')

local reloaded = History.new({
  name = 'persist-test',
  max_entries = 3,
  persist = true,
  path = path,
})
assert_eq(reloaded:previous('search', ''), 'local-new', '应从磁盘重新加载最新记录')
assert_eq(reloaded:previous('search', 'local-new'), 'external-new', '外部记录合并后应继续存在')
assert_eq(reloaded:previous('search', 'external-new'), 'price', '重新加载后应保留更早记录')
assert_eq(reloaded:previous('replace', ''), '$100', '重新加载后应保留其他字段')

local entries = vim.fn.readdir(root)
assert_eq(#entries, 1, '原子写入不得残留临时文件')
assert_eq(entries[1], 'history.json', '目录中应只保留最终历史文件')

local blocked_parent = vim.fs.joinpath(root, 'blocked-parent')
vim.fn.writefile({ 'not a directory' }, blocked_parent, 'b')
local blocked = History.new({
  name = 'blocked-test',
  max_entries = 3,
  persist = true,
  path = vim.fs.joinpath(blocked_parent, 'history.json'),
})
local notices = {}
local original_notify = vim.notify
vim.notify = function(message, level)
  notices[#notices + 1] = { message = message, level = level }
end
assert(blocked:record('search', 'not-written'), '持久化失败时内存记录仍应接受本次输入')
vim.notify = original_notify
assert(#notices == 1, '持久化失败时应只发出一次警告')
assert(notices[1].message:match('Failed to save history:'),
  '持久化失败时应报告统一的保存错误')
assert(vim.uv.fs_stat(vim.fs.joinpath(blocked_parent, 'history.json')) == nil,
  '持久化失败时不应留下伪造的历史文件')

cleanup()
print('通过：vv-utils history 内存与持久化行为')
