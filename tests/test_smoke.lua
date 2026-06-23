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

-- 7. editor.copy_path
test('editor.copy_path: 函数存在', function()
  package.loaded['vv-utils.editor'] = nil
  local ed = require('vv-utils.editor')
  assert(type(ed.copy_path) == 'function', 'editor.copy_path 应为函数')
end)

test('editor.copy_path: 外部 path + silent 复制绝对路径', function()
  local ed = require('vv-utils.editor')
  local tmp = vim.fn.tempname()
  vim.fn.writefile({ '' }, tmp)
  local got = ed.copy_path({ path = tmp, notify = false })
  assert(got == tmp or got == vim.fn.fnamemodify(tmp, ':p'),
    '期望返回绝对路径, 实际: ' .. tostring(got))
  vim.fn.delete(tmp)
end)

test('editor.copy_path: 显式行号范围 line={l1,l2}', function()
  local ed = require('vv-utils.editor')
  local tmp = vim.fn.tempname()
  vim.fn.writefile({ '' }, tmp)
  local got = ed.copy_path({ path = tmp, line = { 18, 29 }, notify = false })
  assert(got and got:match(':18%-29$'),
    '期望以 :18-29 结尾, 实际: ' .. tostring(got))

  local single = ed.copy_path({ path = tmp, line = { 42, 42 }, notify = false })
  -- 用精确的范围模式判断「无范围」，避免误匹配路径里的连字符（如 /tmp/claude-1000/...）
  assert(single and single:match(':42$') and not single:match(':%d+%-%d+$'),
    '相同 l1 l2 应输出单行格式 :42（无范围）, 实际: ' .. tostring(single))

  local reversed = ed.copy_path({ path = tmp, line = { 99, 50 }, notify = false })
  assert(reversed and reversed:match(':50%-99$'),
    'l1>l2 应自动交换为 :50-99, 实际: ' .. tostring(reversed))

  vim.fn.delete(tmp)
end)

test('editor.copy_path: 无路径时返回 nil', function()
  local ed = require('vv-utils.editor')
  -- 当前 buffer 是脚本文件，先切到无名 buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  local got = ed.copy_path({ notify = false })
  assert(got == nil, '空 buffer 应返回 nil, 实际: ' .. tostring(got))
end)

-- 8. scroll.lua
test('scroll.setup: 默认滚动时长配置', function()
  package.loaded['vv-utils.scroll'] = nil
  local scroll = require('vv-utils.scroll')
  scroll.setup()
  local cfg = scroll.get_config()

  assert(cfg.duration == 180, 'duration 默认应为 180，实际: ' .. tostring(cfg.duration))
  assert(cfg.key_duration == 120, 'key_duration 默认应为 120，实际: ' .. tostring(cfg.key_duration))
  assert(cfg.auto_duration == 108, 'auto_duration 默认应为 108，实际: ' .. tostring(cfg.auto_duration))
  assert(cfg.auto_max_steps == 10, 'auto_max_steps 默认应为 10，实际: ' .. tostring(cfg.auto_max_steps))
end)

test('scroll.window: 滚动到目标 topline', function()
  package.loaded['vv-utils.scroll'] = nil
  local scroll = require('vv-utils.scroll')
  scroll.setup({ frame_ms = 1, duration = 100, mouse_step = 3 })

  local win = vim.api.nvim_get_current_win()
  local prev_buf = vim.api.nvim_win_get_buf(win)
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {}

  for i = 1, 200 do
    lines[i] = tostring(i)
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].scrolloff = 0
  vim.api.nvim_win_set_cursor(win, { 20, 0 })
  vim.fn.winrestview({ topline = 1, lnum = 20, col = 0 })

  scroll.window(win, 5)
  local ok = vim.wait(1000, function()
    return vim.fn.winsaveview().topline == 6
  end, 5)

  local view = vim.fn.winsaveview()
  vim.api.nvim_win_set_buf(win, prev_buf)
  vim.api.nvim_buf_delete(buf, { force = true })

  assert(ok, '滚动未在 1000ms 内完成，当前 topline=' .. tostring(view.topline))
  assert(view.topline == 6, '期望 topline=6，实际: ' .. tostring(view.topline))
  assert(vim.o.mousescroll == 'ver:3,hor:6',
    'mousescroll 应为 ver:3,hor:6，实际: ' .. vim.o.mousescroll)
end)

test('scroll.window: 手动滚动期间抑制自动跳转动画', function()
  package.loaded['vv-utils.scroll'] = nil
  local scroll = require('vv-utils.scroll')
  scroll.setup({ frame_ms = 20, key_duration = 100, mouse_step = 3 })

  local win = vim.api.nvim_get_current_win()
  local prev_buf = vim.api.nvim_win_get_buf(win)
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {}

  for i = 1, 200 do
    lines[i] = tostring(i)
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].scrolloff = 0
  vim.api.nvim_win_set_cursor(win, { 20, 0 })
  vim.fn.winrestview({ topline = 1, lnum = 20, col = 0 })

  scroll.window(win, 5)
  assert(scroll._auto_suppressed(), '手动平滑滚动期间应抑制 WinScrolled 自动跳转')

  local ok = vim.wait(1000, function()
    return vim.fn.winsaveview().topline == 6 and not scroll._auto_suppressed()
  end, 5)

  local view = vim.fn.winsaveview()
  local suppressed = scroll._auto_suppressed()
  vim.api.nvim_win_set_buf(win, prev_buf)
  vim.api.nvim_buf_delete(buf, { force = true })

  assert(ok, '手动滚动结束后 suppression 应恢复，topline=' .. view.topline .. ', suppressed=' .. tostring(suppressed))
end)

test('scroll.window: key_duration 可独立限制键盘动画时长', function()
  package.loaded['vv-utils.scroll'] = nil
  local scroll = require('vv-utils.scroll')
  scroll.setup({ frame_ms = 100, duration = 900, key_duration = 5, mouse_step = 3 })

  local win = vim.api.nvim_get_current_win()
  local prev_buf = vim.api.nvim_win_get_buf(win)
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {}

  for i = 1, 200 do
    lines[i] = tostring(i)
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].scrolloff = 0
  vim.api.nvim_win_set_cursor(win, { 20, 0 })
  vim.fn.winrestview({ topline = 1, lnum = 20, col = 0 })

  scroll.window(win, 10)
  local ok = vim.wait(250, function()
    return vim.fn.winsaveview().topline == 11
  end, 5)

  local view = vim.fn.winsaveview()
  vim.api.nvim_win_set_buf(win, prev_buf)
  vim.api.nvim_buf_delete(buf, { force = true })

  assert(ok, 'key_duration 未在 250ms 内限制动画时长，当前 topline=' .. tostring(view.topline))
end)

test('scroll.mouse: 默认鼠标原生，不注册平滑滚轮映射', function()
  package.loaded['vv-utils.scroll'] = nil
  local scroll = require('vv-utils.scroll')
  scroll.setup({ mouse_step = 4 })

  local win = vim.api.nvim_get_current_win()
  local prev_buf = vim.api.nvim_win_get_buf(win)
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {}

  for i = 1, 200 do
    lines[i] = tostring(i)
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].scrolloff = 0
  vim.api.nvim_win_set_cursor(win, { 20, 0 })
  vim.fn.winrestview({ topline = 1, lnum = 20, col = 0 })

  local down_map = vim.fn.maparg('<ScrollWheelDown>', 'n', false, true)
  assert(not down_map or down_map.desc ~= 'vv-scroll: mouse scroll down',
    '默认 native 不应注册 ScrollWheelDown 平滑滚动映射')

  scroll.mouse('down', win)
  local view = vim.fn.winsaveview()

  vim.api.nvim_win_set_buf(win, prev_buf)
  vim.api.nvim_buf_delete(buf, { force = true })

  assert(view.topline == 5, '期望 topline=5，实际: ' .. tostring(view.topline))
  assert(vim.o.mousescroll == 'ver:4,hor:6',
    'mousescroll 应为 ver:4,hor:6，实际: ' .. vim.o.mousescroll)
end)

test('scroll.mouse: smooth 模式注册滚轮映射', function()
  package.loaded['vv-utils.scroll'] = nil
  local scroll = require('vv-utils.scroll')
  scroll.setup({ mouse = 'smooth', frame_ms = 1, duration = 100, mouse_step = 4 })

  local win = vim.api.nvim_get_current_win()
  local prev_buf = vim.api.nvim_win_get_buf(win)
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {}

  for i = 1, 200 do
    lines[i] = tostring(i)
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].scrolloff = 0
  vim.api.nvim_win_set_cursor(win, { 20, 0 })
  vim.fn.winrestview({ topline = 1, lnum = 20, col = 0 })

  local down_map = vim.fn.maparg('<ScrollWheelDown>', 'n', false, true)
  assert(down_map and down_map.desc == 'vv-scroll: mouse scroll down',
    'smooth 模式应注册 ScrollWheelDown 平滑滚动映射')

  vim.api.nvim_feedkeys(
    vim.api.nvim_replace_termcodes('<ScrollWheelDown>', true, false, true),
    'mtx',
    false
  )

  local ok = vim.wait(1000, function()
    return vim.fn.winsaveview().topline == 5
  end, 5)

  local view = vim.fn.winsaveview()
  vim.api.nvim_win_set_buf(win, prev_buf)
  vim.api.nvim_buf_delete(buf, { force = true })

  assert(ok, 'smooth 鼠标滚轮未在 1000ms 内完成，当前 topline=' .. tostring(view.topline))
  assert(view.topline == 5, '期望 topline=5，实际: ' .. tostring(view.topline))
end)

test('scroll.mouse: native 模式会移除 vv-scroll 鼠标映射', function()
  package.loaded['vv-utils.scroll'] = nil
  local scroll = require('vv-utils.scroll')
  scroll.setup({ mouse = 'native', mouse_step = 4 })

  local down_map = vim.fn.maparg('<ScrollWheelDown>', 'n', false, true)
  assert(not down_map or down_map.desc ~= 'vv-scroll: mouse scroll down',
    'native 模式应移除 ScrollWheelDown 平滑滚动映射')
end)

test('scroll.mouse: 滚动鼠标所在窗口而非焦点窗口', function()
  package.loaded['vv-utils.scroll'] = nil
  local scroll = require('vv-utils.scroll')
  scroll.setup({ mouse_step = 4 })

  local original_getmousepos = vim.fn.getmousepos
  local focus_win = vim.api.nvim_get_current_win()
  local focus_buf = vim.api.nvim_create_buf(false, true)
  local target_buf = vim.api.nvim_create_buf(false, true)
  local lines = {}

  for i = 1, 200 do
    lines[i] = tostring(i)
  end

  vim.api.nvim_buf_set_lines(focus_buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_lines(target_buf, 0, -1, false, lines)
  vim.api.nvim_win_set_buf(focus_win, focus_buf)
  vim.wo[focus_win].scrolloff = 0
  vim.api.nvim_win_set_cursor(focus_win, { 20, 0 })
  vim.api.nvim_win_call(focus_win, function()
    vim.fn.winrestview({ topline = 1, lnum = 20, col = 0 })
  end)

  vim.cmd('vsplit')
  local target_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(target_win, target_buf)
  vim.wo[target_win].scrolloff = 0
  vim.api.nvim_win_set_cursor(target_win, { 20, 0 })
  vim.api.nvim_win_call(target_win, function()
    vim.fn.winrestview({ topline = 1, lnum = 20, col = 0 })
  end)

  vim.api.nvim_set_current_win(focus_win)
  vim.fn.getmousepos = function()
    return { winid = target_win, line = 3, column = 1 }
  end

  scroll.mouse('down')
  local focus_topline = vim.api.nvim_win_call(focus_win, function()
    return vim.fn.winsaveview().topline
  end)
  local target_topline = vim.api.nvim_win_call(target_win, function()
    return vim.fn.winsaveview().topline
  end)

  vim.fn.getmousepos = original_getmousepos
  vim.api.nvim_set_current_win(target_win)
  vim.cmd('close')
  vim.api.nvim_set_current_win(focus_win)
  vim.api.nvim_buf_delete(focus_buf, { force = true })
  vim.api.nvim_buf_delete(target_buf, { force = true })

  assert(target_topline == 5, '鼠标所在窗口期望 topline=5，实际: ' .. tostring(target_topline))
  assert(focus_topline == 1, '焦点窗口不应滚动，实际 topline=' .. tostring(focus_topline))
end)

test('scroll.auto: auto_duration 会压缩自动跳转分步预算', function()
  package.loaded['vv-utils.scroll'] = nil
  local scroll = require('vv-utils.scroll')

  scroll.setup({
    frame_ms = 20,
    duration = 900,
    auto_duration = 40,
    auto = true,
    auto_min_lines = 2,
    auto_max_steps = 60,
  })
  assert(scroll._auto_step_count(240) == 3,
    'auto_duration=40/frame_ms=20 时大跳转应拆 3 步，实际: ' .. scroll._auto_step_count(240))

  scroll.setup({
    frame_ms = 20,
    duration = 900,
    auto_duration = 200,
    auto = true,
    auto_min_lines = 2,
    auto_max_steps = 60,
  })
  assert(scroll._auto_step_count(240) == 11,
    'auto_duration=200/frame_ms=20 时大跳转应拆 11 步，实际: ' .. scroll._auto_step_count(240))

  scroll.setup({
    frame_ms = 20,
    duration = 900,
    auto_duration = 200,
    auto = true,
    auto_min_lines = 2,
    auto_max_steps = 5,
  })
  assert(scroll._auto_step_count(240) == 5,
    'auto_max_steps 应继续限制分步数，实际: ' .. scroll._auto_step_count(240))
end)

test('scroll.with_view_animation: 包装显式视口跳转', function()
  package.loaded['vv-utils.scroll'] = nil
  local scroll = require('vv-utils.scroll')
  scroll.setup({
    frame_ms = 1,
    auto_duration = 40,
    auto = true,
    auto_min_lines = 2,
    auto_max_steps = 20,
  })

  local win = vim.api.nvim_get_current_win()
  local prev_buf = vim.api.nvim_win_get_buf(win)
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {}

  for i = 1, 200 do
    lines[i] = tostring(i)
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].scrolloff = 0
  vim.api.nvim_win_set_cursor(win, { 20, 0 })
  vim.fn.winrestview({ topline = 1, lnum = 20, col = 0 })

  local ok = scroll.with_view_animation(win, function()
    vim.api.nvim_win_set_cursor(0, { 45, 0 })
    vim.fn.winrestview({ topline = 40, lnum = 45, col = 0 })
  end)
  assert(ok, 'with_view_animation 应返回 true')

  local done = vim.wait(1000, function()
    return vim.api.nvim_win_call(win, function()
      return vim.fn.winsaveview().topline
    end) == 40
  end, 5)

  local view = vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview()
  end)
  vim.api.nvim_win_set_buf(win, prev_buf)
  vim.api.nvim_buf_delete(buf, { force = true })

  assert(done, '显式跳转动画未在 1000ms 内完成，当前 topline=' .. tostring(view.topline))
end)

test('scroll.auto: scrollbind 窗口跳过自动动画', function()
  local src = table.concat(vim.fn.readfile(plugin_root .. '/lua/vv-utils/scroll.lua'), '\n')
  local guard_at = src:find("nvim_get_option_value%('scrollbind'", 1)
  local busy_at = src:find('if auto_busy%[win_id%] then', 1)

  assert(guard_at, 'WinScrolled handler 应检查 scrollbind')
  assert(busy_at and guard_at < busy_at,
    'scrollbind guard 必须早于 auto_busy/start_auto_scroll 分支')
  assert(src:find('auto_state%[win_id%]%s*=%s*new_state', guard_at),
    '跳过自动动画前仍应更新 auto_state，避免状态滞后')
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
