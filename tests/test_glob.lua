-- vv-utils.glob 搜索简写编译测试
local this = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
local plugin_root = vim.fn.fnamemodify(this, ':h:h')

package.path = table.concat({
  plugin_root .. '/lua/?.lua',
  plugin_root .. '/lua/?/init.lua',
  package.path,
}, ';')

local glob = require('vv-utils.glob')
local passed = 0

local function assert_list(name, actual, expected)
  assert(vim.deep_equal(actual, expected), ('%s\n期望：%s\n实际：%s'):format(
    name,
    vim.inspect(expected),
    vim.inspect(actual)
  ))
  passed = passed + 1
  print('PASS: ' .. name)
end

local split = assert(glob.split('*.{ts,tsx}, **/*.test.ts, **/[a,b].txt, file\\,name.txt, path with spaces/**'))
assert_list('brace / 字符类 / 转义逗号 / 空格路径不被误拆', split, {
  '*.{ts,tsx}',
  '**/*.test.ts',
  '**/[a,b].txt',
  'file\\,name.txt',
  'path with spaces/**',
})

assert_list('普通路径在任意深度同时匹配本体和后代', assert(glob.compile_rg('core/src')), {
  '**/core/src/**',
  '**/core/src',
})

assert_list('./ 路径锚定搜索根', assert(glob.compile_rg('./packages/core/src/')), {
  '/packages/core/src/**',
  '/packages/core/src',
})

assert_list('Windows 分隔符规范化后保持 ./ 语义', assert(glob.compile_rg([[.\packages\core\src\]])), {
  '/packages/core/src/**',
  '/packages/core/src',
})

assert_list('无扩展名输入不猜测文件或目录', assert(glob.compile_rg('LICENSE')), {
  '**/LICENSE/**',
  '**/LICENSE',
})

assert_list('扩展名简写对齐 VS Code', assert(glob.compile_rg('.js')), {
  '**/*.js/**',
  '**/*.js',
})

assert_list('显式 globstar 不重复扩展', assert(glob.compile_rg('**/*.ts')), {
  '**/*.ts/**',
  '**/*.ts',
})

assert_list('! 前缀同时排除本体和后代', assert(glob.compile_rg('!test')), {
  '!**/test/**',
  '!**/test',
})

assert_list('调用方可强制生成排除 pattern', assert(glob.compile_rg('test', { negate = true })), {
  '!**/test/**',
  '!**/test',
})

local compiled = assert(glob.compile_rg_list('*.{ts,tsx}, ./packages/core/src/', { negate = true }))
assert_list('列表编译保持条目和展开顺序', compiled, {
  '!**/*.{ts,tsx}/**',
  '!**/*.{ts,tsx}',
  '!/packages/core/src/**',
  '!/packages/core/src',
})

local _, brace_error = glob.split('*.{ts,tsx')
assert(brace_error == 'unclosed { in glob pattern', brace_error)
passed = passed + 1
print('PASS: 拒绝未闭合 brace')

local _, class_error = glob.split('**/[ab')
assert(class_error == 'unclosed [ in glob pattern', class_error)
passed = passed + 1
print('PASS: 拒绝未闭合字符类')

local _, parent_error = glob.compile_rg('../shared')
assert(parent_error and parent_error:find('change Cwd', 1, true), parent_error)
passed = passed + 1
print('PASS: 拒绝越过搜索根的路径')

local _, absolute_error = glob.compile_rg('/private/tmp/project')
assert(absolute_error and absolute_error:find('change Cwd', 1, true), absolute_error)
passed = passed + 1
print('PASS: 拒绝绝对路径')

print(('%d PASS / 0 FAIL'):format(passed))
