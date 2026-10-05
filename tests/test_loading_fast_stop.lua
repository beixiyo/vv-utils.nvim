-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  root = vim.env.VV_TEST_REPO
  vim.opt.runtimepath:prepend(root)

  Loading = require('vv-utils.loading')
  Handle = require('vv-utils.loading.handle')
  Clock = require('vv-utils.loading.clock')

  original_notify = vim.notify
  notified = {}
  vim.notify = function(msg, level)
    notified[#notified + 1] = { msg = msg, level = level }
  end

  ---@param fn fun()
  function in_fast_event(fn)
    local timer = assert(vim.uv.new_timer())
    local done = false
    timer:start(0, 0, function()
      fn()
      timer:close()
      done = true
    end)
    vim.wait(1000, function() return done end)
  end
end)

T["fast event 停止延后 UI 清理但立即释放时钟"] = function()
  child.lua_func(function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'hello' })
    local mark = Loading.mark({ buf = buf, get_pos = function() return { row = 1 } end, interval_ms = 10000 })
    local on_stop_runs = 0
    mark:on_stop(function() on_stop_runs = on_stop_runs + 1 end)
    assert(#vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, {}) == 1, '前置条件：mark 必须已画出 extmark')
    assert(#vim.api.nvim_get_autocmds({ event = 'BufWipeout', buffer = buf }) == 1, '前置条件：必须注册 BufWipeout')

    local fast_ok, fast_err = true, nil
    in_fast_event(function()
      fast_ok, fast_err = pcall(function()
        mark:stop()
        mark:stop()
      end)
    end)
    local inactive_after_fast = not mark:is_active()
    mark:stop()
    vim.wait(200, function() return false end)

    local extmarks_left = #vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, {})
    local autocmds_left = #vim.api.nvim_get_autocmds({ event = 'BufWipeout', buffer = buf })
    local timers_left = Clock._timer_count()
    local notes_fast = vim.deepcopy(notified)
    notified = {}
    assert(fast_ok, 'fast event 中 stop 不得抛错：' .. tostring(fast_err))
    assert(inactive_after_fast, 'fast event 中 stop 必须同步把 handle 置为停止')
    assert(extmarks_left == 0, 'fast event 中 stop 后 extmark 必须在主循环中被清除：' .. extmarks_left)
    assert(autocmds_left == 0, 'fast event 中 stop 后 BufWipeout autocmd 必须被删除')
    assert(on_stop_runs == 1, 'on_stop 必须恰好执行一次：' .. on_stop_runs)
    assert(timers_left == 0, '不得残留时钟 timer：' .. timers_left)
    assert(#notes_fast == 0, 'fast event 中正常 stop 不得产生通知：' .. vim.inspect(notes_fast))
  end)
end

T["清理抛错必须报告而非静默丢弃"] = function()
  child.lua_func(function()
    local cleared_on_stop = 0
    local h = Handle.new({
      frames = { 'a' },
      interval_ms = 10000,
      delay_ms = 0,
      render = function() end,
      clear = function() error('clear boom') end,
    })
    h:on_stop(function() cleared_on_stop = cleared_on_stop + 1 end)
    local clear_ok, clear_err = pcall(h.stop, h)
    local notes_clear = vim.deepcopy(notified)
    local timers_after_clear = Clock._timer_count()
    notified = {}
    assert(clear_ok, 'clear 抛错不得让 stop 抛出：' .. tostring(clear_err))
    assert(not h:is_active(), 'clear 抛错后 handle 仍必须停止')
    assert(timers_after_clear == 0, 'clear 抛错后时钟订阅必须已释放')
    assert(cleared_on_stop == 1, 'clear 抛错不得阻止 on_stop 执行')
    assert(#notes_clear == 1, 'clear 抛错必须报告一次：' .. vim.inspect(notes_clear))
    assert(notes_clear[1].level == vim.log.levels.ERROR, 'clear 错误必须以 ERROR 级报告')
    assert(notes_clear[1].msg:find('vv-utils.loading: clear failed', 1, true), '报告必须带模块前缀：' .. notes_clear[1].msg)
    assert(notes_clear[1].msg:find('clear boom', 1, true), '报告必须包含原始错误：' .. notes_clear[1].msg)
  end)
end

T["迟到 on_stop 主循环立即执行且 fast event 延后"] = function()
  child.lua_func(function()
    local h = Handle.new({ frames = { 'a' }, interval_ms = 10000, delay_ms = 0, render = function() end, clear = function() end })
    h:stop()
    local late_ok, late_err = pcall(h.on_stop, h, function() error('late boom') end)
    local notes_late = vim.deepcopy(notified)
    notified = {}

    local late_fast_ran = 0
    local late_fast_ok = true
    in_fast_event(function()
      late_fast_ok = pcall(h.on_stop, h, function()
        late_fast_ran = late_fast_ran + 1
        vim.api.nvim_get_current_buf() -- fast event 中会失败的 vim API
        error('late fast boom')
      end)
    end)
    vim.wait(200, function() return #notified > 0 end)
    local notes_late_fast = vim.deepcopy(notified)
    notified = {}
    assert(late_ok, '停止后注册的 on_stop 抛错不得抛给调用方：' .. tostring(late_err))
    assert(#notes_late == 1 and notes_late[1].level == vim.log.levels.ERROR, '停止后 on_stop 抛错必须以 ERROR 报告：' .. vim.inspect(notes_late))
    assert(notes_late[1].msg:find('vv-utils.loading: on_stop failed', 1, true), '报告必须带模块前缀：' .. notes_late[1].msg)
    assert(notes_late[1].msg:find('late boom', 1, true), '报告必须包含原始错误')

    assert(late_fast_ok, 'fast event 中注册的迟到 on_stop 不得抛给调用方')
    assert(late_fast_ran == 1, 'fast event 中注册的迟到 on_stop 必须执行一次：' .. late_fast_ran)
    assert(#notes_late_fast == 1 and notes_late_fast[1].msg:find('late fast boom', 1, true),
      '迟到 on_stop 必须在主循环执行（vim API 可用）并报告其自身错误：' .. vim.inspect(notes_late_fast))
  end)
end

T["延后清理前主循环再次 stop 同步完成清理"] = function()
  child.lua_func(function()
    local buf2 = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf2, 0, -1, false, { 'hello' })
    local mark2 = Loading.mark({ buf = buf2, get_pos = function() return { row = 1 } end, interval_ms = 10000 })
    local mark2_on_stop = 0
    mark2:on_stop(function() mark2_on_stop = mark2_on_stop + 1 end)
    assert(#vim.api.nvim_buf_get_extmarks(buf2, -1, 0, -1, {}) == 1, '前置条件：mark2 必须已画出 extmark')

    local resync = { ran = false }
    in_fast_event(function()
      vim.schedule(function()
        resync.ran = true
        resync.extmarks_before = #vim.api.nvim_buf_get_extmarks(buf2, -1, 0, -1, {})
        resync.on_stop_before = mark2_on_stop
        mark2:stop()
        resync.extmarks_after = #vim.api.nvim_buf_get_extmarks(buf2, -1, 0, -1, {})
        resync.on_stop_after = mark2_on_stop
      end)
      mark2:stop()
    end)
    vim.wait(200, function() return false end)
    local mark2_on_stop_final = mark2_on_stop
    local extmarks2_final = #vim.api.nvim_buf_get_extmarks(buf2, -1, 0, -1, {})
    local notes_resync = vim.deepcopy(notified)
    vim.api.nvim_buf_delete(buf2, { force = true })
    assert(resync.ran, '主循环检查函数必须执行')
    assert(resync.extmarks_before == 1 and resync.on_stop_before == 0, '前置条件：检查函数必须先于延后清理执行：' .. vim.inspect(resync))
    assert(resync.extmarks_after == 0, '延后清理前主循环再 stop，返回时 extmark 必须已清除：' .. vim.inspect(resync))
    assert(resync.on_stop_after == 1, '延后清理前主循环再 stop，返回时 on_stop 必须已执行一次：' .. vim.inspect(resync))
    assert(mark2_on_stop_final == 1, '延后清理随后执行时不得重复执行 on_stop：' .. mark2_on_stop_final)
    assert(extmarks2_final == 0, 'extmark 不得残留')
    assert(#notes_resync == 0, '不得产生通知：' .. vim.inspect(notes_resync))
  end)
end

T['fast event 释放并发 slot 只退回旧文案且不误停共享显示'] = function()
  child.lua_func(function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'target' })
    local handle
    local slot = Loading.slot(function()
      handle = Loading.mark({ buf = buf, get_pos = function() return { row = 1 } end, interval_ms = 10000 })
      return handle
    end)
    local first = slot:acquire('first-request')
    local second = slot:acquire('second-request')
    local ok, err, active
    in_fast_event(function()
      ok, err = pcall(second)
      active = handle:is_active()
    end)
    assert(ok, 'fast event 中 release 不得抛错：' .. tostring(err))
    assert(active and slot:is_busy(), '旧请求仍在途，不得因文案重画误停共享 handle')
    assert(vim.wait(1000, function()
      local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
      for _, mark in ipairs(marks) do
        for _, chunk in ipairs(mark[4].virt_text or {}) do
          if vim.trim(chunk[1]) == 'first-request' then return true end
        end
      end
      return false
    end), '文案应在主循环退回仍在途的旧请求')
    assert(#notified == 0, '合法 release 不应产生渲染失败通知：' .. vim.inspect(notified))
    first()
    slot:dispose()
    assert(not handle:is_active() and Clock._timer_count() == 0, '全部释放后应停止显示并释放时钟')
  end)
end

return T
