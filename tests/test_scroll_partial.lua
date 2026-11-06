local H = dofile('tests/helpers.lua')
local T, child = H.new_set()

T['非焦点窗口局部采集保留基线并正确读取制表符、宽字符和虚拟列'] = function()
  child.lua_func(function()
    local eq = Helpers.eq
    local animation = require('vv-utils.scroll.animation')
    local state = require('vv-utils.scroll.state')
    local focus = vim.api.nvim_get_current_win()
    vim.cmd('vnew')
    local target = vim.api.nvim_get_current_win()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { '基线' })
    vim.wo[0][0].scrolloff = 0
    vim.wo[0][0].virtualedit = ''
    animation.track_state(target)
    local tracked = state.runtime.auto_state[target]
    local baseline = vim.deepcopy(tracked)
    local view = tracked.view

    -- 故意改变完整采集所读的字段，局部采集仍只能替换 cursor
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '另一缓冲区', '\t界x', '\t界x' })
    vim.bo[buf].tabstop = 8
    vim.api.nvim_win_set_buf(target, buf)
    vim.wo[target][0].scrolloff = 2
    vim.wo[target][0].virtualedit = 'all'
    vim.api.nvim_set_current_win(focus)
    local focus_cursor = vim.api.nvim_win_get_cursor(focus)
    local winsaveview = vim.fn.winsaveview
    local captures = 0
    vim.fn.winsaveview = function()
      captures = captures + 1
      return winsaveview()
    end

    for _, position in ipairs({
      { line = 2, column = 0, virtcol = 8 },
      { line = 2, column = 1, virtcol = 10 },
      { line = 3, virtual = 20, virtcol = 20 },
    }) do
      vim.api.nvim_win_call(target, function()
        vim.wo[0][0].virtualedit = position.virtual and 'all' or ''
        vim.api.nvim_win_set_cursor(0, { position.line, position.column or 0 })
        if position.virtual then vim.cmd('normal! ' .. position.virtual .. '|') end
      end)
      animation.track_state_partial(target)
      baseline.cursor = { line = position.line, virtcol = position.virtcol }
      eq(tracked, baseline, '局部采集必须只更新目标窗口的行号和屏幕虚拟列')
      assert(state.runtime.auto_state[target] == tracked and tracked.view == view,
        '局部采集不得替换完整状态或视图基线')
      eq(vim.api.nvim_get_current_win(), focus, '采集后必须保留焦点窗口')
      eq(vim.api.nvim_win_get_cursor(focus), focus_cursor, '采集不得移动焦点窗口光标')
    end
    vim.fn.winsaveview = winsaveview
    eq(captures, 0, '局部采集不得再调用 winsaveview 进行完整视图采集')
  end)
end

T['未跟踪、动画忙碌、采集失败和无效窗口均保留原状态'] = function()
  child.lua_func(function()
    local eq = Helpers.eq
    local animation = require('vv-utils.scroll.animation')
    local state = require('vv-utils.scroll.state')
    local focus = vim.api.nvim_get_current_win()
    vim.cmd('vnew')
    local target = vim.api.nvim_get_current_win()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { '起点', '新的光标位置' })
    animation.track_state_partial(target)
    eq(state.runtime.auto_state, {}, '未跟踪窗口不得创建局部状态')
    animation.track_state(target)
    local tracked = state.runtime.auto_state[target]
    local baseline = vim.deepcopy(tracked)
    local cursor = tracked.cursor
    vim.api.nvim_win_set_cursor(target, { 2, 3 })
    vim.api.nvim_set_current_win(focus)

    state.runtime.auto_busy[target] = true
    animation.track_state_partial(target)
    eq(tracked, baseline, '动画忙碌期间不得更新光标')
    state.runtime.auto_busy[target] = nil

    -- 真实窗口仍有效，但底层虚拟列读取抛错：不得发布半份光标或泄露异常
    local virtcol = vim.fn.virtcol
    local attempts = 0
    vim.fn.virtcol = function()
      attempts = attempts + 1
      error('测试虚拟列采集失败')
    end
    local ok, err = pcall(animation.track_state_partial, target)
    vim.fn.virtcol = virtcol
    assert(ok, '采集失败必须安静退出：' .. tostring(err))
    eq(attempts, 1, '失败场景必须实际进入目标窗口的虚拟列采集')
    eq(tracked, baseline, '采集失败必须保留整份旧状态')
    assert(tracked.cursor == cursor, '采集失败不得替换光标对象')
    eq(vim.api.nvim_get_current_win(), focus, '失败后仍须恢复焦点窗口')

    vim.api.nvim_win_close(target, true)
    animation.track_state_partial(target)
    eq(tracked, baseline, '失效窗口不得改变已有状态')
    assert(state.runtime.auto_state[target] == tracked, '失效窗口不得删除跟踪基线')
  end)
end

T['局部光标更新作为后续大跳转插值起点且保留原视图基线'] = function()
  child.lua_func(function()
    local eq = Helpers.eq
    local animation = require('vv-utils.scroll.animation')
    local state = require('vv-utils.scroll.state')
    local viewport = require('vv-utils.scroll.viewport')
    state.setup({ frame_ms = 100, auto_duration = 100, auto_max_steps = 2 })
    local win = vim.api.nvim_get_current_win()
    local lines = {}
    for i = 1, 200 do lines[i] = string.rep('x', 40) end
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    vim.wo[0][0].scrolloff = 0
    vim.wo[0][0].virtualedit = ''
    vim.fn.winrestview({ topline = 1, lnum = 5, col = 0 })
    animation.track_state(win)
    local baseline_view = vim.deepcopy(state.runtime.auto_state[win].view)
    vim.api.nvim_win_set_cursor(win, { 12, 16 })
    animation.track_state_partial() -- 省略窗口时仍采集当前已跟踪窗口
    eq(state.runtime.auto_state[win].cursor, { line = 12, virtcol = 17 }, '移动后更新光标基线')
    eq(state.runtime.auto_state[win].view, baseline_view, '光标移动不得覆盖跳转前视图')

    vim.fn.winrestview({ topline = 80, lnum = 85, col = 20, curswant = 20 })
    local target = viewport.capture_state(win)
    animation.on_win_scrolled({ match = tostring(win) })
    assert(state.runtime.auto_busy[win], '大跳转必须实际启动自动动画')
    eq(viewport.capture_view(win).topline, 1, '动画必须从保留的旧视图开始')
    assert(vim.wait(1000, function()
      local captured = state.runtime.auto_state[win]
      return captured.view.topline == 40
    end, 1), '必须观察到真实 timer 驱动的第一帧')
    eq(state.runtime.auto_state[win].cursor, { line = 49, virtcol = 19 },
      '第一帧必须从局部更新的光标插值，不能使用完整采集时的旧光标')
    assert(vim.wait(1000, function() return not state.runtime.auto_busy[win] end, 1),
      '自动动画必须完成并释放忙碌状态')
    eq(viewport.capture_state(win), target, '完成后必须恢复目标视图、光标与选项')
    eq(state.runtime.auto_state[win], target, '下一次跳转必须使用完成后的完整基线')
    assert(not state.runtime.auto_timer[win], '完成后必须释放自动动画 timer')
  end)
end

return T
