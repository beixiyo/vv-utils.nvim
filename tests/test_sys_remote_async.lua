-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  root = vim.env.VV_TEST_REPO
  vim.opt.runtimepath:prepend(root)

  original_system = vim.system
  original_notify = vim.notify
  original_tmux = vim.env.TMUX

  -- 不在 tmux：只会执行一次 ps；ps 结果在下一轮事件循环异步返回，确保走协程挂起 → 恢复路径
  vim.env.TMUX = nil
  vim.system = function(_, _, on_exit)
    vim.schedule(function() on_exit({ code = 0, stdout = '1 0 launchd\n' }) end)
    return { kill = function() end }
  end

  notified = {}
  vim.notify = function(msg, level)
    notified[#notified + 1] = { msg = msg, level = level }
  end

  Remote = require('vv-utils.sys.remote')
end)

T["远程检测回调报错明确通知"] = function()
  child.lua_func(function()
    local Remote = require('vv-utils.sys.remote')

    local called = false
    Remote.is_remote_async(function()
      called = true
      error('callback boom')
    end)
    vim.wait(1000, function() return #notified > 0 end)

    vim.system = original_system
    vim.notify = original_notify
    vim.env.TMUX = original_tmux

    assert(called, 'callback 必须被调用')
    assert(#notified == 1, 'callback 抛错必须被报告，不得被 coroutine.resume 静默吞掉')
    assert(notified[1].level == vim.log.levels.ERROR, '错误必须以 ERROR 级别报告')
    assert(notified[1].msg:find('callback boom', 1, true), '报告必须包含原始错误：' .. notified[1].msg)
  end)
end

T["启动失败也必须异步调用回调"] = function()
  child.lua_func(function()
    vim.system = original_system
    -- callback 必须始终异步：PATH 里没有 ps 时 vim.system 同步抛错，旧实现不挂起协程，
    -- callback 在 is_remote_async 返回前就被同步调用（正常路径则是异步），时序不一致
    local original_path = vim.env.PATH
    local empty_dir = vim.fn.tempname()
    vim.fn.mkdir(empty_dir, 'p')
    vim.env.TMUX = nil
    vim.env.PATH = empty_dir
    assert(not pcall(vim.system, { 'ps' }), '前置条件：PATH 中没有 ps 时 vim.system 必须同步抛错')

    local async_called, returned = false, false
    local called_before_return = nil
    local ok_async, async_err = pcall(Remote.is_remote_async, function()
      async_called = true
      called_before_return = not returned
    end)
    returned = true
    vim.wait(1000, function() return async_called end)

    vim.env.PATH = original_path
    vim.env.TMUX = original_tmux
    vim.fn.delete(empty_dir, 'rf')

    assert(ok_async, 'is_remote_async 不得抛错：' .. tostring(async_err))
    assert(async_called, 'ps 不可用时 callback 仍必须被调用')
    assert(called_before_return == false, 'callback 不得在 is_remote_async 返回前被同步调用')
  end)
end

return T
