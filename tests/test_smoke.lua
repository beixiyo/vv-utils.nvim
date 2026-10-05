-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  this = vim.fn.fnamemodify((vim.env.VV_TEST_REPO .. '/tests/test_smoke.lua'), ':p')
  plugin_root = vim.fn.fnamemodify(this, ':h:h')
  vendors_root = vim.fn.fnamemodify(plugin_root, ':h')
  icons_root = assert(vim.env.VV_TEST_ICONS, '诊断图标测试需要 VV_TEST_ICONS 指向已安装 vv-icons 源码')
  package.path = table.concat({
    plugin_root .. '/lua/?.lua',
    plugin_root .. '/lua/?/init.lua',
    icons_root .. '/lua/?.lua',
    icons_root .. '/lua/?/init.lua',
    package.path,
  }, ';')
end)

T["诊断严重级别使用共享图标与对应高亮"] = function()
  child.lua_func(function()
    do
      package.loaded['vv-utils.diagnostics'] = nil
      local D = require('vv-utils.diagnostics')
      local icons = require('vv-icons')
      local sym = D.symbol_for({ [vim.diagnostic.severity.ERROR] = 1 })
      assert(sym and sym.glyph == icons.diagnostics_error, '期望 vv-icons error glyph')
      assert(sym and sym.hl == 'DiagnosticError', '期望 DiagnosticError, 实际: ' .. (sym and sym.hl or 'nil'))
    end
    do
      local D = require('vv-utils.diagnostics')
      local icons = require('vv-icons')
      local sym = D.symbol_for({ [vim.diagnostic.severity.WARN] = 1 })
      assert(sym and sym.glyph == icons.diagnostics_warn, '期望 vv-icons warn glyph')
      assert(sym and sym.hl == 'DiagnosticWarn', '期望 DiagnosticWarn, 实际: ' .. (sym and sym.hl or 'nil'))
    end
    do
      local D = require('vv-utils.diagnostics')
      local icons = require('vv-icons')
      local sym = D.symbol_for({ [vim.diagnostic.severity.INFO] = 1 })
      assert(sym and sym.glyph == icons.diagnostics_info, '期望 vv-icons info glyph')
      assert(sym and sym.hl == 'DiagnosticInfo', '期望 DiagnosticInfo, 实际: ' .. (sym and sym.hl or 'nil'))
    end
    do
      local D = require('vv-utils.diagnostics')
      local icons = require('vv-icons')
      local sym = D.symbol_for({ [vim.diagnostic.severity.HINT] = 1 })
      assert(sym and sym.glyph == icons.diagnostics_hint, '期望 vv-icons hint glyph')
      assert(sym and sym.hl == 'DiagnosticHint', '期望 DiagnosticHint, 实际: ' .. (sym and sym.hl or 'nil'))
    end
  end)
end

T["color: Hex RGBA 经 alpha 合成输出可用 Hex"] = function()
  child.lua_func(function()
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
end

T["hl: register_dimmed 向目标背景降低前景对比度"] = function()
  child.lua_func(function()
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
end

T["git: 统一识别 unmerged 状态并解析完整冲突块"] = function()
  child.lua_func(function()
    package.loaded['vv-utils.git'] = nil
      local git = require('vv-utils.git')

      for _, xy in ipairs({ 'DD', 'AU', 'UD', 'UA', 'DU', 'AA', 'UU' }) do
        assert(git.is_conflict(xy), xy .. ' 应识别为冲突状态')
        local symbol = git.symbol_for(xy)
        assert(symbol.glyph == '!' and symbol.hl == 'VVGitConflict', xy .. ' 未使用共享冲突装饰')
      end
      for _, xy in ipairs({ 'M ', ' M', 'AM', '??' }) do
        assert(not git.is_conflict(xy), xy .. ' 不应识别为冲突状态')
      end

      local hunks = git.parse_conflict_hunks({
        'before',
        '<<<<<<< ours',
        'ordinary ours',
        '=======',
        'ordinary theirs',
        '>>>>>>> theirs',
        'middle',
        '<<<<<<< ours',
        'diff3 ours',
        '||||||| base',
        'base content',
        '=======',
        'diff3 theirs',
        '>>>>>>> theirs',
        'after',
      })

      assert(#hunks == 2, '应解析普通与 diff3/zdiff3 两个完整冲突块')
      assert(hunks[1].start_line == 2 and hunks[1].base_line == nil
          and hunks[1].separator_line == 4 and hunks[1].end_line == 6,
        '普通冲突块坐标错误')
      assert(hunks[2].start_line == 8 and hunks[2].base_line == 10
          and hunks[2].separator_line == 12 and hunks[2].end_line == 14,
        'diff3/zdiff3 冲突块坐标错误')
      assert(#git.parse_conflict_hunks({ '<<<<<<< ours', 'unfinished' }) == 0,
        '不完整冲突块不应发布')
      assert(#git.parse_conflict_hunks({
        '<<<<<<<<<<<<<<<< banner', 'log', '======== section', 'more', '>>>>>>>>>>>>>>>> end',
      }) == 0, '超过七个标记字符的分隔横幅不是 Git 冲突标记')
      assert(#git.parse_conflict_hunks({
        '<<<<<<<x', 'a', '=======y', 'b', '>>>>>>>z',
      }) == 0, '七个标记字符后紧跟非空格的文本不是 Git 冲突标记')
      assert(#git.parse_conflict_hunks({ '<<<<<<<', 'a', '=======', 'b', '>>>>>>>' }) == 1,
        '无标签的裸冲突标记仍应识别')
  end)
end

T["git: parse_diff_lines 行级 A/C/D"] = function()
  child.lua_func(function()
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
end

T["git: highlight_specs 返回不污染静态基准的副本"] = function()
  child.lua_func(function()
    local git = require('vv-utils.git')
      local first = git.highlight_specs()
      local original_fg = first.VVGitAdded.fg
      first.VVGitAdded.bold = true
      first.VVGitAdded.fg = '#000000'
      local second = git.highlight_specs()
      assert(second.VVGitAdded.fg == original_fg, '调用方修改不能污染后续基准色')
      assert(second.VVGitAdded.bold == nil, '调用方属性不能残留到后续基准')
  end)
end

T["git: diff_lines 支持 worktree、staged、revision 与 index stage source"] = function()
  child.lua_func(function()
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
        assert(vim.wait(3000, function() return done end), '等待 diff_lines 回调超时')
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

      vim.fn.system({ 'git', '-C', tmp_dir, 'checkout', '-qb', 'conflict-theirs' })
      vim.fn.writefile({ 'one', 'theirs', 'staged', 'three' }, changed)
      vim.fn.system({ 'git', '-C', tmp_dir, 'add', 'changed.txt' })
      vim.fn.system({ 'git', '-C', tmp_dir, 'commit', '-qm', 'theirs' })
      vim.fn.system({ 'git', '-C', tmp_dir, 'checkout', '-qb', 'conflict-ours', 'HEAD^' })
      vim.fn.writefile({ 'one', 'ours', 'staged', 'three' }, changed)
      vim.fn.system({ 'git', '-C', tmp_dir, 'add', 'changed.txt' })
      vim.fn.system({ 'git', '-C', tmp_dir, 'commit', '-qm', 'ours' })
      vim.fn.system({ 'git', '-C', tmp_dir, 'merge', '--no-edit', 'conflict-theirs' })

      local conflict_new = diff('changed.txt', {
        root = tmp_dir,
        from_index_stage = 2,
        to_index_stage = 3,
        side = 'new',
      })
      assert(conflict_new[2] == 'C', 'index stage source 应把 ours-to-theirs 差异投影到 theirs')

      local conflict_abs = diff(changed, {
        root = tmp_dir,
        from_index_stage = 2,
        to_index_stage = 3,
        side = 'new',
      })
      assert(conflict_abs and conflict_abs[2] == 'C',
        'index stage source 应接受与 DiffSource.path 契约一致的绝对路径')

      local invalid_stage_called = false
      git.diff_lines('changed.txt', function(result)
        invalid_stage_called = result == nil
      end, { root = tmp_dir, from_index_stage = 2 })
      assert(invalid_stage_called, 'index stage source 缺少配对 stage 时应拒绝请求')

      vim.fn.delete(tmp_dir, 'rf')
  end)
end

T["git: diff_line_sets 同时返回 staged / unstaged 并映射到 worktree"] = function()
  child.lua_func(function()
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
      assert(vim.wait(3000, function() return done end), '等待 diff_line_sets 回调超时')
      assert(sets and sets.staged[3] == 'A', 'staged 第 2 行应在 worktree 中映射到第 3 行')
      assert(sets and sets.unstaged[1] == 'A', 'worktree 新增行应显示 unstaged marker')
      assert(sets and sets.unstaged[3] == 'C', '暂存后再次修改应显示 unstaged marker')

      vim.fn.delete(tmp_dir, 'rf')
  end)
end

T["hl.lua: apply() 不修改原始 specs"] = function()
  child.lua_func(function()
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
end

T["fs: write_all 原子写入"] = function()
  child.lua_func(function()
    local fs_io = require('vv-utils.fs.io')
      local fs_operations = require('vv-utils.fs.operations')
      local fs_path = require('vv-utils.fs.path')
      local tmp_dir = vim.fn.tempname()
      vim.fn.mkdir(tmp_dir, 'p')
      local test_path = tmp_dir .. '/atomic_test.txt'

      fs_io.write_all(test_path, 'hello atomic')
      local content = fs_io.read_all(test_path)
      assert(content == 'hello atomic', '内容不匹配: ' .. content)
      assert(not fs_path.exists(test_path .. '.tmp'), '不应残留 .tmp 文件')

      -- 覆盖写入需保留已有文件权限（尤其脚本可执行位）
      assert(vim.uv.fs_chmod(test_path, 511)) -- 0o777，验证显式 chmod 不受 umask 影响
      fs_io.write_all(test_path, 'overwritten')
      local content2 = fs_io.read_all(test_path)
      assert(content2 == 'overwritten', '覆盖写入内容不匹配: ' .. content2)
      local stat = assert(vim.uv.fs_stat(test_path))
      assert(stat.mode % 4096 == 511, '覆盖写入后应保留 0o777，实际: ' .. tostring(stat.mode % 4096))

      local target_path = tmp_dir .. '/target.txt'
      local link_path = tmp_dir .. '/link.txt'
      fs_io.write_all(target_path, 'before')
      assert(vim.uv.fs_symlink('target.txt', link_path))
      fs_io.write_all(link_path, 'after')
      assert(assert(vim.uv.fs_lstat(link_path)).type == 'link', '覆盖写入不应替换 symlink 本身')
      assert(fs_io.read_all(target_path) == 'after', '覆盖 symlink 应写入真实目标')

      local scan = assert(vim.uv.fs_scandir(tmp_dir))
      while true do
        local name = vim.uv.fs_scandir_next(scan)
        if not name then break end
        assert(not name:match('%.tmp%.'), '不应残留唯一临时文件: ' .. name)
      end

      fs_operations.delete(tmp_dir)
  end)
end

T["sys.open_default: 转发路径并报告 opener 失败"] = function()
  child.lua_func(function()
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
end

T["复制路径支持绝对路径、行范围且拒绝无名 buffer"] = function()
  child.lua_func(function()
    do
      local ed = require('vv-utils.editor')
        local tmp = vim.fn.tempname()
        vim.fn.writefile({ '' }, tmp)
        local got = ed.copy_path({ path = tmp, notify = false })
        assert(got == tmp or got == vim.fn.fnamemodify(tmp, ':p'),
          '期望返回绝对路径, 实际: ' .. tostring(got))
        vim.fn.delete(tmp)
    end
    do
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
    end
    do
      local ed = require('vv-utils.editor')
        -- 当前 buffer 是脚本文件，先切到无名 buffer
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_set_current_buf(buf)
        local got = ed.copy_path({ notify = false })
        assert(got == nil, '空 buffer 应返回 nil, 实际: ' .. tostring(got))
    end
  end)
end





T["滚动默认配置与真实窗口动画落点"] = function()
  child.lua_func(function()
    do
      package.loaded['vv-utils.scroll'] = nil
        local scroll = require('vv-utils.scroll')
        scroll.setup()
        local cfg = scroll.get_config()

        assert(cfg.duration == 180, 'duration 默认应为 180，实际: ' .. tostring(cfg.duration))
        assert(cfg.key_duration == 120, 'key_duration 默认应为 120，实际: ' .. tostring(cfg.key_duration))
        assert(cfg.auto_duration == 108, 'auto_duration 默认应为 108，实际: ' .. tostring(cfg.auto_duration))
        assert(cfg.auto_max_steps == 10, 'auto_max_steps 默认应为 10，实际: ' .. tostring(cfg.auto_max_steps))
    end
    do
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
    end
  end)
end



T["scroll.window: 手动滚动期间抑制自动跳转动画"] = function()
  child.lua_func(function()
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
end

T["scroll.with_auto_suppressed: 即时跳转不回弹为自动动画"] = function()
  child.lua_func(function()
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
end

T["scroll.auto: scrollbind 窗口保持原生同步"] = function()
  child.lua_func(function()
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
end

T["scroll.window: key_duration 可独立限制键盘动画时长"] = function()
  child.lua_func(function()
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
end

T["scroll.mouse: 默认鼠标原生，不注册平滑滚轮映射"] = function()
  child.lua_func(function()
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
end

T["scroll.mouse: smooth 模式注册滚轮映射"] = function()
  child.lua_func(function()
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
end

T["scroll.mouse: native 模式会移除 vv-scroll 鼠标映射"] = function()
  child.lua_func(function()
    package.loaded['vv-utils.scroll'] = nil
      local scroll = require('vv-utils.scroll')
      scroll.setup({ mouse = 'native', mouse_step = 4 })

      local down_map = vim.fn.maparg('<ScrollWheelDown>', 'n', false, true)
      assert(not down_map or down_map.desc ~= 'vv-scroll: mouse scroll down',
        'native 模式应移除 ScrollWheelDown 平滑滚动映射')
  end)
end

T["scroll.mouse: 滚动鼠标所在窗口而非焦点窗口"] = function()
  child.lua_func(function()
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
end

T["scroll.with_view_animation: 包装显式视口跳转"] = function()
  child.lua_func(function()
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
end

return T
