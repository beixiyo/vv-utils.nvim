-- vv-utils.nvim 变更验证脚本
-- 运行方式：
--   cd vv-utils.nvim && nvim --headless -u NONE -l tests/test_smoke.lua
--   或在 nvim 内:  :luafile vv-utils.nvim/tests/test_smoke.lua

-- 让 require('vv-utils.xxx') 在 -u NONE 下也能工作
local this = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
local plugin_root = vim.fn.fnamemodify(this, ':h:h')
package.path = plugin_root .. '/lua/?.lua;' .. plugin_root .. '/lua/?/init.lua;' .. package.path

local passed = 0
local failed = 0
local results = {}

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    table.insert(results, '[PASS] ' .. name)
  else
    failed = failed + 1
    table.insert(results, '[FAIL] ' .. name .. ': ' .. tostring(err))
  end
end

-- 1. path.lua: "lua" 不在 root_patterns 中
test('path.lua: root_patterns 不含 "lua"', function()
  local src = vim.fn.readfile(plugin_root .. '/lua/vv-utils/path.lua')
  for _, line in ipairs(src) do
    if line:match('root_patterns') and line:match('"lua"') then
      error('root_patterns 仍包含 "lua"')
    end
  end
end)

-- 2. diagnostics.lua: 高亮组已重命名为 VVDiag*
test('diagnostics.lua: VVDiagError', function()
  package.loaded['vv-utils.diagnostics'] = nil
  local D = require('vv-utils.diagnostics')
  local sym = D.symbol_for({ [vim.diagnostic.severity.ERROR] = 1 })
  assert(sym and sym.hl == 'VVDiagError', '期望 VVDiagError, 实际: ' .. (sym and sym.hl or 'nil'))
end)

test('diagnostics.lua: VVDiagWarn', function()
  local D = require('vv-utils.diagnostics')
  local sym = D.symbol_for({ [vim.diagnostic.severity.WARN] = 1 })
  assert(sym and sym.hl == 'VVDiagWarn', '期望 VVDiagWarn, 实际: ' .. (sym and sym.hl or 'nil'))
end)

test('diagnostics.lua: VVDiagInfo', function()
  local D = require('vv-utils.diagnostics')
  local sym = D.symbol_for({ [vim.diagnostic.severity.INFO] = 1 })
  assert(sym and sym.hl == 'VVDiagInfo', '期望 VVDiagInfo, 实际: ' .. (sym and sym.hl or 'nil'))
end)

test('diagnostics.lua: VVDiagHint', function()
  local D = require('vv-utils.diagnostics')
  local sym = D.symbol_for({ [vim.diagnostic.severity.HINT] = 1 })
  assert(sym and sym.hl == 'VVDiagHint', '期望 VVDiagHint, 实际: ' .. (sym and sym.hl or 'nil'))
end)

test('diagnostics.lua: 不含旧名 VVExplorerDiag', function()
  local src = vim.fn.readfile(plugin_root .. '/lua/vv-utils/diagnostics.lua')
  for _, line in ipairs(src) do
    if line:match('VVExplorerDiag[EWIH]') then
      error('仍包含旧高亮组名: ' .. line)
    end
  end
end)

-- 3. hl.lua: 不修改传入的 specs
test('hl.lua: apply() 不修改原始 specs', function()
  package.loaded['vv-utils.hl'] = nil
  local hl = require('vv-utils.hl')
  local specs = { TestHlNoMutate = { fg = '#abcdef' } }
  hl.register('test-no-mutate', specs)
  assert(specs.TestHlNoMutate.default == nil,
    '原始 spec 被修改: default = ' .. tostring(specs.TestHlNoMutate.default))
  -- 清理
  vim.api.nvim_del_augroup_by_name('test-no-mutate')
  vim.api.nvim_set_hl(0, 'TestHlNoMutate', {})
end)

-- 4. fs.lua: 原子写入
test('fs.lua: write_all 原子写入', function()
  package.loaded['vv-utils.fs'] = nil
  local fs = require('vv-utils.fs')
  local tmp_dir = vim.fn.tempname()
  vim.fn.mkdir(tmp_dir, 'p')
  local test_path = tmp_dir .. '/atomic_test.txt'

  fs.write_all(test_path, 'hello atomic')
  local content = fs.read_all(test_path)
  assert(content == 'hello atomic', '内容不匹配: ' .. content)
  assert(not fs.exists(test_path .. '.tmp'), '不应残留 .tmp 文件')

  -- 覆盖写入测试
  fs.write_all(test_path, 'overwritten')
  local content2 = fs.read_all(test_path)
  assert(content2 == 'overwritten', '覆盖写入内容不匹配: ' .. content2)

  fs.delete(tmp_dir)
end)

-- 5. sys.lua: 使用 vim.ui.open
test('sys.lua: 使用 vim.ui.open 而非 jobstart', function()
  local src = vim.fn.readfile(plugin_root .. '/lua/vv-utils/sys.lua')
  local has_vim_ui_open = false
  local has_jobstart = false
  for _, line in ipairs(src) do
    if line:match('vim%.ui%.open') then has_vim_ui_open = true end
    if line:match('jobstart') then has_jobstart = true end
  end
  assert(has_vim_ui_open, '应使用 vim.ui.open')
  assert(not has_jobstart, '不应再使用 jobstart')
end)

test('sys.lua: 不含平台检测代码', function()
  local src = vim.fn.readfile(plugin_root .. '/lua/vv-utils/sys.lua')
  for _, line in ipairs(src) do
    assert(not line:match('xdg%-open'), '不应包含 xdg-open: ' .. line)
    assert(not line:match("has%('mac'%)"), "不应包含 has('mac'): " .. line)
  end
end)

-- 6. README.md: 文档完整性
test('README.md: 包含 bufdelete 文档', function()
  local src = vim.fn.readfile(plugin_root .. '/README.md')
  local found = false
  for _, line in ipairs(src) do
    if line:match('vv%-utils%.bufdelete') then found = true; break end
  end
  assert(found, 'README 缺少 bufdelete 模块文档')
end)

test('README.md: 包含 editor 文档', function()
  local src = vim.fn.readfile(plugin_root .. '/README.md')
  local found = false
  for _, line in ipairs(src) do
    if line:match('vv%-utils%.editor') then found = true; break end
  end
  assert(found, 'README 缺少 editor 模块文档')
end)

test('README.md: 包含 bigfile 文档', function()
  local src = vim.fn.readfile(plugin_root .. '/README.md')
  local found = false
  for _, line in ipairs(src) do
    if line:match('vv%-utils%.bigfile') then found = true; break end
  end
  assert(found, 'README 缺少 bigfile 模块文档')
end)

test('README.md: bigfile 需要 setup 的说明', function()
  local src = vim.fn.readfile(plugin_root .. '/README.md')
  local found = false
  for _, line in ipairs(src) do
    if line:match('bigfile') and line:match('setup') then found = true; break end
  end
  assert(found, 'README 应说明 bigfile 需要 setup()')
end)

test('README.md: git 模块不含 toplevel', function()
  local src = vim.fn.readfile(plugin_root .. '/README.md')
  for _, line in ipairs(src) do
    if line:match('toplevel') then
      error('README 仍包含 toplevel: ' .. line)
    end
  end
end)

test('README.md: 包含 read_all', function()
  local src = vim.fn.readfile(plugin_root .. '/README.md')
  local found = false
  for _, line in ipairs(src) do
    if line:match('read_all') then found = true; break end
  end
  assert(found, 'README 应包含 read_all')
end)

test('README.md: 包含 get_fg', function()
  local src = vim.fn.readfile(plugin_root .. '/README.md')
  local found = false
  for _, line in ipairs(src) do
    if line:match('get_fg') then found = true; break end
  end
  assert(found, 'README 应包含 get_fg')
end)

-- 输出结果
print(string.rep('─', 50))
print('vv-utils.nvim 变更验证结果')
print(string.rep('─', 50))
for _, r in ipairs(results) do
  print(r)
end
print(string.rep('─', 50))
print(string.format('共 %d 项: %d 通过, %d 失败', passed + failed, passed, failed))
if failed > 0 then
  print('有测试未通过！')
else
  print('全部通过')
end
