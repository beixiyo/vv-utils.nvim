-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  root = vim.env.VV_TEST_REPO
  vim.opt.runtimepath:prepend(root)

  original_system = vim.system
  original_notify = vim.notify
  saved_env = {
    TMUX = vim.env.TMUX,
    SSH_TTY = vim.env.SSH_TTY,
    SSH_CONNECTION = vim.env.SSH_CONNECTION,
  }

  function restore()
    vim.system = original_system
    vim.notify = original_notify
    for k, v in pairs(saved_env) do vim.env[k] = v end
  end

  notified = {}
  vim.notify = function(msg, level)
    notified[#notified + 1] = { msg = msg, level = level }
  end

  -- 看起来像远程的输出：tmux client 200 与 nvim 自身都挂在 sshd 下
  pid = vim.uv.os_getpid()
  PS_OUT = ('%d 100 nvim\n200 100 tmux\n100 1 sshd\n'):format(pid)

  ---@param cmd string[]
  ---@return vim.SystemCompleted
  function result_for(cmd)
    local stdout = cmd[1] == 'tmux' and '200\n' or PS_OUT
    return { code = 0, signal = 15, stdout = stdout, stderr = '' }
  end

  vim.system = function(cmd, _, on_exit)
    local res = result_for(cmd)
    if on_exit then
      vim.schedule(function() on_exit(res) end)
      return { kill = function() end }
    end
    return { wait = function() return res end }
  end

  vim.env.TMUX = '/tmp/vv-utils-fake-tmux,1,0'
  vim.env.SSH_CONNECTION = nil

  Remote = require('vv-utils.sys.remote')
  ---@return boolean?
  function async_result()
    local got
    Remote.is_remote_async(function(r) got = r end)
    vim.wait(1000, function() return got ~= nil end)
    return got
  end
end)

T["信号终止按失败处理且同步异步结论一致"] = function()
  child.lua_func(function()
    local clients = Remote.tmux_clients()

    vim.env.SSH_TTY = nil
    local sync_no_ssh = Remote.is_remote()
    local async_no_ssh = async_result()

    vim.env.SSH_TTY = '/dev/ttys999'
    local sync_ssh = Remote.is_remote()
    local async_ssh = async_result()
    assert(clients == nil, '被信号终止的命令必须按失败处理，tmux_clients 应返回 nil：' .. vim.inspect(clients))
    assert(sync_no_ssh == false, '进程链不可用且无 SSH 变量时 is_remote 必须为 false')
    assert(async_no_ssh == false, 'is_remote_async 必须与同步结论一致（无 SSH 变量）：' .. tostring(async_no_ssh))
    assert(sync_ssh == true, '进程链不可用但有 SSH_TTY 时 is_remote 必须为 true')
    assert(async_ssh == true, 'is_remote_async 必须与同步结论一致（有 SSH_TTY）：' .. tostring(async_ssh))
  end)
end

T["同步退出后启动抛错不重复恢复协程"] = function()
  child.lua_func(function()
    vim.env.TMUX = nil
    vim.env.SSH_TTY = nil
    vim.system = function(_, _, on_exit)
      on_exit({ code = 0, signal = 0, stdout = '1 0 launchd\n', stderr = '' })
      error('spawn late boom')
    end
    local calls = 0
    Remote.is_remote_async(function() calls = calls + 1 end)
    vim.wait(200, function() return false end)

    local notes = notified
    restore()
    assert(calls == 1, 'vim.system 抛错后 callback 仍必须恰好调用一次：' .. calls)
    assert(#notes == 0, '不得出现错误报告（如 resume 已结束的协程）：' .. vim.inspect(notes))
  end)
end

return T
