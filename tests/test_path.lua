-- vv-utils.path 纯函数测试
local this = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
local plugin_root = vim.fn.fnamemodify(this, ':h:h')

package.path = table.concat({
  plugin_root .. '/lua/?.lua',
  plugin_root .. '/lua/?/init.lua',
  package.path,
}, ';')

local path = require('vv-utils.path')
local passed = 0

local function test(name, actual, expected)
  assert(actual == expected, ('%s\n期望：%s\n实际：%s'):format(name, expected, actual))
  passed = passed + 1
  print('PASS: ' .. name)
end

test(
  '折叠相对路径的中间层级',
  path.collapse_middle('frontend/electron/renderer/views/cards/[id]/components/CardSummary/index.tsx'),
  'frontend/…/components/CardSummary/index.tsx'
)

test(
  '层级未超过限制时保持原样',
  path.collapse_middle('renderer/components/App.tsx'),
  'renderer/components/App.tsx'
)

test(
  '保留绝对路径前缀',
  path.collapse_middle('/Users/es/Documents/code/frontend/App.tsx', { head = 1, tail = 2 }),
  '/Users/…/frontend/App.tsx'
)

test(
  '支持 Windows 路径分隔符',
  path.collapse_middle([[C:\Users\es\Documents\code\App.tsx]], { head = 1, tail = 2 }),
  [[C:\Users\…\code\App.tsx]]
)

test(
  '允许自定义保留层级与省略标记',
  path.collapse_middle('a/b/c/d/e.lua', { head = 2, tail = 1, ellipsis = '...' }),
  'a/b/.../e.lua'
)

local fixture = vim.fn.tempname()
local repository = fixture .. '/repository'
local frontend = repository .. '/apps/web'
local source = frontend .. '/src/App.tsx'
vim.fn.mkdir(frontend .. '/src', 'p')
vim.fn.mkdir(repository .. '/.git', 'p')
vim.fn.writefile({ '{}' }, frontend .. '/package.json')
vim.fn.writefile({ 'export {}' }, source)

test(
  'Git 根优先于 monorepo 子包 manifest',
  path.find_root(source),
  vim.fs.normalize(repository)
)

local standalone = fixture .. '/standalone/service'
local standalone_source = standalone .. '/lib/main.rs'
vim.fn.mkdir(standalone .. '/lib', 'p')
vim.fn.writefile({ '[package]' }, standalone .. '/Cargo.toml')
vim.fn.writefile({ 'fn main() {}' }, standalone_source)

test(
  '没有 Git 时回退到最近的语言 manifest',
  path.find_root(standalone_source),
  vim.fs.normalize(standalone)
)

test('未命中项目标识时返回 nil', path.find_root(fixture .. '/orphan/file.txt'), nil)

local worktree = fixture .. '/worktree'
local worktree_source = worktree .. '/src/main.lua'
vim.fn.mkdir(worktree .. '/src', 'p')
vim.fn.writefile({ 'gitdir: ../git/worktrees/test' }, worktree .. '/.git')
vim.fn.writefile({ 'return {}' }, worktree_source)

test('支持 worktree 的 .git 文件', path.find_root(worktree_source), vim.fs.normalize(worktree))

local ignored = fixture .. '/ignored'
local ignored_source = ignored .. '/src/main.lua'
vim.fn.mkdir(ignored .. '/src', 'p')
vim.fn.writefile({ 'build/' }, ignored .. '/.gitignore')
vim.fn.writefile({ 'return {}' }, ignored_source)

test('.gitignore 不作为项目根标记', path.find_root(ignored_source), nil)

vim.fn.delete(fixture, 'rf')

print(('%d PASS / 0 FAIL'):format(passed))
