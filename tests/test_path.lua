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

print(('%d PASS / 0 FAIL'):format(passed))
