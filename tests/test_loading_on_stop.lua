-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  root = vim.env.VV_TEST_REPO
  vim.opt.runtimepath:prepend(root)

  Loading = require('vv-utils.loading')
  Clock = require('vv-utils.loading.clock')

  original_notify = vim.notify
  notified = {}
  vim.notify = function(msg, level)
    notified[#notified + 1] = { msg = msg, level = level }
  end
end)

T["停止回调报错仍释放显示与延迟资源且幂等"] = function()
  child.lua_func(function()
    -- 已显示（订阅时钟）的 handle
    local active = Loading.ticker({ interval_ms = 10000, on_frame = function() end })
    local after_ran = 0
    active:on_stop(function() error('on_stop boom') end)
    active:on_stop(function() after_ran = after_ran + 1 end)
    local ok_stop, stop_err = pcall(active.stop, active)
    active:stop()

    -- 尚在 delay 期间（持有延迟 timer）的 handle
    local delayed = Loading.ticker({ delay_ms = 10000, on_frame = function() end })
    delayed:on_stop(function() error('delayed boom') end)
    delayed:stop()

    -- 给经 vim.schedule 发出的通知留出时间
    vim.wait(100, function() return #notified >= 2 end)
    vim.notify = original_notify

    assert(ok_stop, 'on_stop 抛错不得让 stop 抛出：' .. tostring(stop_err))
    assert(not active:is_active() and not delayed:is_active(), 'on_stop 抛错后 handle 仍必须处于停止状态')
    assert(Clock._timer_count() == 0, 'on_stop 抛错后时钟订阅必须已释放')
    assert(delayed._delay_timer == nil, 'on_stop 抛错后延迟 timer 必须已释放')
    assert(after_ran == 1, '前一个 on_stop 抛错时后续 on_stop 仍须执行且只执行一次：' .. after_ran)
    assert(#notified == 2, 'on_stop 抛错必须各报告一次（重复 stop 不重复报告）：' .. vim.inspect(notified))
    for _, n in ipairs(notified) do
      assert(n.level == vim.log.levels.ERROR, 'on_stop 错误必须以 ERROR 级别报告')
      assert(n.msg:find('vv-utils.loading: on_stop failed', 1, true), '报告必须带模块前缀：' .. n.msg)
    end
    assert(notified[1].msg:find('on_stop boom', 1, true), '报告必须包含原始错误：' .. notified[1].msg)
    assert(notified[2].msg:find('delayed boom', 1, true), '报告必须包含原始错误：' .. notified[2].msg)
  end)
end

return T
