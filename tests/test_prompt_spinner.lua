-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  root = vim.env.VV_TEST_REPO
  vim.opt.runtimepath:prepend(root)

  Clock = require('vv-utils.loading.clock')

  original_notify = vim.notify
  notified = {}
  vim.notify = function(msg, level)
    notified[#notified + 1] = { msg = msg, level = level }
  end

  boom = false
  redraws = 0
  Prompt = require('vv-utils.prompt')
  handle = assert(Prompt.open(vim.api.nvim_get_current_win(), {
    spinner = { interval_ms = 10 },
    get_mode = function()
      redraws = redraws + 1
      if boom then error('redraw boom') end
      return nil
    end,
    on_change = function() end,
    on_accept = function() end,
    on_cancel = function() end,
  }))

  ---@param ms integer
  function wait(ms) vim.wait(ms, function() return false end) end
end)

T["绘制报错停止后可再次开启且关闭释放时钟"] = function()
  child.lua_func(function()
    -- 1：redraw 抛错 → ticker handle 自行停止
    handle.set_busy(true, 'searching')
    assert(Clock._timer_count() == 1, 'set_busy(true) 必须启动 spinner')
    boom = true
    vim.wait(500, function() return #notified > 0 end)
    boom = false
    assert(#notified > 0 and notified[1].msg:find('redraw boom', 1, true), 'redraw 抛错必须被报告：' .. vim.inspect(notified))
    assert(Clock._timer_count() == 0, 'redraw 抛错后 ticker 必须自行停止并释放时钟')

    -- 自行停止后再次 busy 必须重建，spinner 继续转（redraw 次数持续增长）
    handle.set_busy(true, 'searching')
    assert(Clock._timer_count() == 1, 'ticker 自行停止后再次 set_busy(true) 必须重建 spinner')
    local before = redraws
    wait(80)
    assert(redraws > before + 1, '重建后 spinner 必须继续出帧：' .. (redraws - before))

    -- 2：停止后再次 busy 能重启
    handle.set_busy(false)
    assert(Clock._timer_count() == 0, 'set_busy(false) 必须停止 spinner 并释放时钟')
    handle.set_busy(true, 'again')
    assert(Clock._timer_count() == 1, 'set_busy(false) 后再次 set_busy(true) 必须重启 spinner')

    handle.close()
    assert(Clock._timer_count() == 0, 'close 必须停止 spinner 并释放时钟')
  end)
end

return T
