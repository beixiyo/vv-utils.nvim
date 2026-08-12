-- vv-utils.nvim 变更验证脚本
-- 运行方式：
--   cd vv-utils.nvim && nvim --headless -u NONE -l tests/test_smoke.lua
--   或在 nvim 内:  :luafile vv-utils.nvim/tests/test_smoke.lua

-- 让 require('vv-utils.xxx') 在 -u NONE 下也能工作
local this = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
local plugin_root = vim.fn.fnamemodify(this, ':h:h')
local vendors_root = vim.fn.fnamemodify(plugin_root, ':h')
local icons_root = vendors_root .. '/vv-icons.nvim'
package.path = table.concat({
  plugin_root .. '/lua/?.lua',
  plugin_root .. '/lua/?/init.lua',
  icons_root .. '/lua/?.lua',
  icons_root .. '/lua/?/init.lua',
  package.path,
}, ';')

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

-- 2. diagnostics.lua: 优先使用 vv-icons 的诊断图标与 Diagnostic* 高亮
test('diagnostics.lua: DiagnosticError icon', function()
  package.loaded['vv-utils.diagnostics'] = nil
  local D = require('vv-utils.diagnostics')
  local icons = require('vv-icons')
  local sym = D.symbol_for({ [vim.diagnostic.severity.ERROR] = 1 })
  assert(sym and sym.glyph == icons.diagnostics_error, '期望 vv-icons error glyph')
  assert(sym and sym.hl == 'DiagnosticError', '期望 DiagnosticError, 实际: ' .. (sym and sym.hl or 'nil'))
end)

test('diagnostics.lua: DiagnosticWarn icon', function()
  local D = require('vv-utils.diagnostics')
  local icons = require('vv-icons')
  local sym = D.symbol_for({ [vim.diagnostic.severity.WARN] = 1 })
  assert(sym and sym.glyph == icons.diagnostics_warn, '期望 vv-icons warn glyph')
  assert(sym and sym.hl == 'DiagnosticWarn', '期望 DiagnosticWarn, 实际: ' .. (sym and sym.hl or 'nil'))
end)

test('diagnostics.lua: DiagnosticInfo icon', function()
  local D = require('vv-utils.diagnostics')
  local icons = require('vv-icons')
  local sym = D.symbol_for({ [vim.diagnostic.severity.INFO] = 1 })
  assert(sym and sym.glyph == icons.diagnostics_info, '期望 vv-icons info glyph')
  assert(sym and sym.hl == 'DiagnosticInfo', '期望 DiagnosticInfo, 实际: ' .. (sym and sym.hl or 'nil'))
end)

test('diagnostics.lua: DiagnosticHint icon', function()
  local D = require('vv-utils.diagnostics')
  local icons = require('vv-icons')
  local sym = D.symbol_for({ [vim.diagnostic.severity.HINT] = 1 })
  assert(sym and sym.glyph == icons.diagnostics_hint, '期望 vv-icons hint glyph')
  assert(sym and sym.hl == 'DiagnosticHint', '期望 DiagnosticHint, 实际: ' .. (sym and sym.hl or 'nil'))
end)

test('color: Hex RGBA 经 alpha 合成输出可用 Hex', function()
  local color = require('vv-utils.color')
  local parsed = color.parse('#0f08')
  assert(
    parsed.r == 0 and parsed.g == 255 and parsed.b == 0 and parsed.a == 136,
    '短 RGBA Hex 未按 CSS 规则展开'
  )
  assert(
    color.to_hex(color.composite(parsed, '#0000ff')) == '#008877',
    'RGBA source-over 合成结果错误'
  )
end)

test('hl: register_dimmed 向目标背景降低前景对比度', function()
  local hl = require('vv-utils.hl')
  hl.register('VVUtilsDimSourceTest', {
    VVUtilsDimSource = { fg = '#00ff00', bold = true },
  }, { default = false })
  vim.api.nvim_set_hl(0, 'VVUtilsDimBackground', { bg = '#000000' })
  hl.register_dimmed('VVUtilsDimTest', {
    VVUtilsDimTarget = 'VVUtilsDimSource',
  }, {
    amount = 0.7,
    background = 'VVUtilsDimBackground',
  })

  local target = vim.api.nvim_get_hl(0, { name = 'VVUtilsDimTarget', link = false })
  assert(target.fg and target.fg > 0 and target.fg < 0x00ff00,
    ('派生前景色应降低对比度，实际 #%06x'):format(target.fg or 0))
  assert(target.bold == true, '派生高亮应保留来源样式')

  vim.api.nvim_set_hl(0, 'VVUtilsDimSource', {})
  vim.api.nvim_set_hl(0, 'VVUtilsDimTarget', {})
  vim.cmd('doautocmd ColorScheme')
  assert(vim.wait(100, function()
    local restored = vim.api.nvim_get_hl(0, { name = 'VVUtilsDimTarget', link = false })
    return restored.fg and restored.fg > 0 and restored.fg < 0x00ff00 and restored.bold == true
  end), 'ColorScheme 后未等待来源高亮恢复再派生')
end)

-- 3. Git 行级 diff 解析
test('git: parse_diff_lines 行级 A/C/D', function()
  package.loaded['vv-utils.git'] = nil
  local git = require('vv-utils.git')
  local got = git.parse_diff_lines(table.concat({
    '@@ -0,0 +1,2 @@',
    '@@ -10,2 +10,3 @@',
    '@@ -20,2 +22,0 @@',
  }, '\n'))

  local want = {
    [1] = 'A',
    [2] = 'A',
    [10] = 'C',
    [11] = 'C',
    [12] = 'A',
    [22] = 'D',
  }

  for lnum, kind in pairs(want) do
    assert(got[lnum] == kind, ('第 %d 行期望 %s，实际 %s'):format(lnum, kind, tostring(got[lnum])))
  end
end)

test('git: highlight_specs 返回不污染静态基准的副本', function()
  local git = require('vv-utils.git')
  local first = git.highlight_specs()
  local original_fg = first.VVGitAdded.fg
  first.VVGitAdded.bold = true
  first.VVGitAdded.fg = '#000000'
  local second = git.highlight_specs()
  assert(second.VVGitAdded.fg == original_fg, '调用方修改不能污染后续基准色')
  assert(second.VVGitAdded.bold == nil, '调用方属性不能残留到后续基准')
end)

test('git: diff_lines 支持 worktree、staged 与任意 revision source', function()
  local git = require('vv-utils.git')
  local tmp_dir = vim.fn.tempname()
  vim.fn.mkdir(tmp_dir, 'p')

  local changed = tmp_dir .. '/changed.txt'
  local removed = tmp_dir .. '/removed.txt'
  vim.fn.writefile({ 'one', 'two', 'three' }, changed)
  vim.fn.writefile({ 'old one', 'old two' }, removed)

  vim.fn.system({ 'git', '-C', tmp_dir, 'init', '-q' })
  vim.fn.system({ 'git', '-C', tmp_dir, 'config', 'user.name', 'vv-utils test' })
  vim.fn.system({ 'git', '-C', tmp_dir, 'config', 'user.email', 'test@example.com' })
  vim.fn.system({ 'git', '-C', tmp_dir, 'add', 'changed.txt', 'removed.txt' })
  vim.fn.system({ 'git', '-C', tmp_dir, 'commit', '-qm', 'initial' })

  vim.fn.writefile({ 'one', 'two', 'staged', 'three' }, changed)
  vim.fn.system({ 'git', '-C', tmp_dir, 'add', 'changed.txt' })
  vim.fn.delete(removed)
  vim.fn.system({ 'git', '-C', tmp_dir, 'add', 'removed.txt' })

  local function diff(path, opts)
    local done = false
    local markers
    git.diff_lines(path, function(result)
      markers = result
      done = true
    end, opts)
    assert(vim.wait(3000, function() return done end), 'diff_lines callback timeout')
    return markers or {}
  end

  local worktree = diff(changed)
  local staged = diff('changed.txt', { root = tmp_dir, mode = 'staged' })
  local deleted = diff('removed.txt', { root = tmp_dir, mode = 'staged', side = 'old' })

  assert(next(worktree) == nil, '纯 staged 文件不应出现在 worktree diff')
  assert(staged[3] == 'A', 'staged 新增行应投影到 index 新侧第 3 行')
  assert(deleted[1] == 'D' and deleted[2] == 'D', 'staged 删除应投影到 HEAD 旧侧原始行')

  vim.fn.system({ 'git', '-C', tmp_dir, 'commit', '-qm', 'second' })
  local revision_new = diff('changed.txt', {
    root = tmp_dir,
    from_rev = 'HEAD^',
    to_rev = 'HEAD',
    side = 'new',
  })
  local revision_old = diff('removed.txt', {
    root = tmp_dir,
    from_rev = 'HEAD^',
    to_rev = 'HEAD',
    side = 'old',
  })

  assert(revision_new[3] == 'A', 'revision source 应把新增行投影到新侧')
  assert(revision_old[1] == 'D' and revision_old[2] == 'D',
    'revision source 应把删除行投影到旧侧')

  vim.fn.delete(tmp_dir, 'rf')
end)

test('git: diff_line_sets 同时返回 staged / unstaged 并映射到 worktree', function()
  local git = require('vv-utils.git')
  local tmp_dir = vim.fn.tempname()
  vim.fn.mkdir(tmp_dir, 'p')
  local path = tmp_dir .. '/both.txt'

  vim.fn.writefile({ 'one', 'two', 'three', 'four' }, path)
  vim.fn.system({ 'git', '-C', tmp_dir, 'init', '-q' })
  vim.fn.system({ 'git', '-C', tmp_dir, 'config', 'user.name', 'vv-utils test' })
  vim.fn.system({ 'git', '-C', tmp_dir, 'config', 'user.email', 'test@example.com' })
  vim.fn.system({ 'git', '-C', tmp_dir, 'add', 'both.txt' })
  vim.fn.system({ 'git', '-C', tmp_dir, 'commit', '-qm', 'initial' })

  vim.fn.writefile({ 'one', 'staged', 'two', 'three', 'four' }, path)
  vim.fn.system({ 'git', '-C', tmp_dir, 'add', 'both.txt' })
  vim.fn.writefile({ 'worktree', 'one', 'staged again', 'two', 'three', 'four' }, path)

  local done = false
  local sets
  git.diff_line_sets(path, function(result)
    sets = result
    done = true
  end)
  assert(vim.wait(3000, function() return done end), 'diff_line_sets callback timeout')
  assert(sets and sets.staged[3] == 'A', 'staged 第 2 行应在 worktree 中映射到第 3 行')
  assert(sets and sets.unstaged[1] == 'A', 'worktree 新增行应显示 unstaged marker')
  assert(sets and sets.unstaged[3] == 'C', '暂存后再次修改应显示 unstaged marker')

  vim.fn.delete(tmp_dir, 'rf')
end)

-- 4. hl.lua: 不修改传入的 specs
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

-- 5. fs 原子写入
test('fs: write_all 原子写入', function()
  package.loaded['vv-utils.fs'] = nil
  local fs = require('vv-utils.fs')
  local tmp_dir = vim.fn.tempname()
  vim.fn.mkdir(tmp_dir, 'p')
  local test_path = tmp_dir .. '/atomic_test.txt'

  fs.write_all(test_path, 'hello atomic')
  local content = fs.read_all(test_path)
  assert(content == 'hello atomic', '内容不匹配: ' .. content)
  assert(not fs.exists(test_path .. '.tmp'), '不应残留 .tmp 文件')

  -- 覆盖写入需保留已有文件权限（尤其脚本可执行位）
  assert(vim.uv.fs_chmod(test_path, 511)) -- 0o777，验证显式 chmod 不受 umask 影响
  fs.write_all(test_path, 'overwritten')
  local content2 = fs.read_all(test_path)
  assert(content2 == 'overwritten', '覆盖写入内容不匹配: ' .. content2)
  local stat = assert(vim.uv.fs_stat(test_path))
  assert(stat.mode % 4096 == 511, '覆盖写入后应保留 0o777，实际: ' .. tostring(stat.mode % 4096))

  local target_path = tmp_dir .. '/target.txt'
  local link_path = tmp_dir .. '/link.txt'
  fs.write_all(target_path, 'before')
  assert(vim.uv.fs_symlink('target.txt', link_path))
  fs.write_all(link_path, 'after')
  assert(assert(vim.uv.fs_lstat(link_path)).type == 'link', '覆盖写入不应替换 symlink 本身')
  assert(fs.read_all(target_path) == 'after', '覆盖 symlink 应写入真实目标')

  local scan = assert(vim.uv.fs_scandir(tmp_dir))
  while true do
    local name = vim.uv.fs_scandir_next(scan)
    if not name then break end
    assert(not name:match('%.tmp%.'), '不应残留唯一临时文件: ' .. name)
  end

  fs.delete(tmp_dir)
end)

-- 6. sys.open_default
test('sys.open_default: 转发路径并报告 opener 失败', function()
  local sys = require('vv-utils.sys')
  local original_open = vim.ui.open
  local original_notify = vim.notify
  local opened_path
  local notice

  vim.ui.open = function(path)
    opened_path = path
    return {}
  end
  assert(sys.open_default('/tmp/vv-utils-open-default.txt'))
  assert(opened_path == '/tmp/vv-utils-open-default.txt', '应把路径传给 Neovim opener')
  assert(not sys.open_default(''), '空路径不应调用 opener')

  vim.ui.open = function() return nil, 'no opener' end
  vim.notify = function(message, level)
    notice = { message = message, level = level }
  end
  assert(not sys.open_default('/tmp/no-opener.txt'), 'opener 失败应返回 false')
  assert(notice and notice.message:find('no opener', 1, true), 'opener 失败应通知原始错误')
  assert(notice.level == vim.log.levels.ERROR, 'opener 失败应使用 error 级别')

  vim.ui.open = original_open
  vim.notify = original_notify
end)

-- 7. editor.copy_path
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

-- 8. scroll
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
  local ok = vim.wait(1000, function()
    return vim.fn.winsaveview().topline == 6
  end, 5)

  local view = vim.fn.winsaveview()
  vim.api.nvim_win_set_buf(win, prev_buf)
  vim.api.nvim_buf_delete(buf, { force = true })

  assert(ok, '手动滚动应正常完成且不被自动跳转打断，topline=' .. view.topline)
end)

test('scroll.with_auto_suppressed: 即时跳转不回弹为自动动画', function()
  package.loaded['vv-utils.scroll'] = nil
  local scroll = require('vv-utils.scroll')
  scroll.setup({ frame_ms = 12, auto_duration = 108, mouse_step = 3 })

  local win = vim.api.nvim_get_current_win()
  local prev_buf = vim.api.nvim_win_get_buf(win)
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {}

  for i = 1, 300 do
    lines[i] = tostring(i)
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].scrolloff = 0

  scroll.with_auto_suppressed(win, function()
    vim.api.nvim_win_set_cursor(win, { 20, 0 })
    vim.fn.winrestview({ topline = 1, lnum = 20, col = 0 })
  end)
  vim.wait(100, function() return not scroll._auto_suppressed() end, 5)

  local ok = scroll.with_auto_suppressed(win, function()
    vim.api.nvim_win_call(win, function()
      vim.cmd('keepjumps normal! 101Gzt')
    end)
  end)
  vim.cmd.redraw()
  local immediate_topline = vim.fn.winsaveview().topline
  vim.wait(150, function() return false end, 10)
  local final_topline = vim.fn.winsaveview().topline

  vim.api.nvim_win_set_buf(win, prev_buf)
  vim.api.nvim_buf_delete(buf, { force = true })

  assert(ok, '即时跳转回调执行失败')
  assert(immediate_topline == 101, '即时跳转后 topline 应为 101，实际: ' .. immediate_topline)
  assert(final_topline == 101, '即时跳转不应回弹或启动自动动画，实际: ' .. final_topline)
end)

test('scroll.auto: scrollbind 窗口保持原生同步', function()
  package.loaded['vv-utils.scroll'] = nil
  local scroll = require('vv-utils.scroll')
  scroll.setup({
    frame_ms = 20,
    auto_duration = 400,
    auto = true,
    auto_min_lines = 2,
    auto_max_steps = 40,
  })

  local first_win = vim.api.nvim_get_current_win()
  local previous_buf = vim.api.nvim_win_get_buf(first_win)
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {}
  for i = 1, 200 do lines[i] = tostring(i) end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_buf(first_win, buf)
  vim.cmd('vsplit')
  local second_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(second_win, buf)

  for _, win in ipairs({ first_win, second_win }) do
    vim.wo[win].scrollbind = true
    vim.wo[win].scrolloff = 0
    scroll.with_auto_suppressed(win, function()
      vim.api.nvim_win_call(win, function()
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        vim.fn.winrestview({ topline = 1, lnum = 1, col = 0 })
      end)
    end)
  end

  vim.api.nvim_set_current_win(first_win)
  vim.cmd('normal! 80Gzt')
  vim.cmd.redraw()
  vim.wait(150, function()
    return vim.api.nvim_win_call(second_win, function()
      return vim.fn.winsaveview().topline
    end) == 80
  end, 5)

  local first_topline = vim.api.nvim_win_call(first_win, function()
    return vim.fn.winsaveview().topline
  end)
  local second_topline = vim.api.nvim_win_call(second_win, function()
    return vim.fn.winsaveview().topline
  end)

  vim.wo[first_win].scrollbind = false
  vim.wo[second_win].scrollbind = false
  vim.api.nvim_set_current_win(second_win)
  vim.cmd('close')
  vim.api.nvim_set_current_win(first_win)
  vim.api.nvim_win_set_buf(first_win, previous_buf)
  vim.api.nvim_buf_delete(buf, { force = true })

  assert(first_topline == 80, '触发窗口不应被自动动画回拉，实际: ' .. first_topline)
  assert(second_topline == 80, 'scrollbind 窗口应原生同步到 80，实际: ' .. second_topline)
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
  vim.cmd('cquit 1')
else
  print('全部通过')
end
