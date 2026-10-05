-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  root = vim.env.VV_TEST_REPO
  vim.opt.runtimepath:prepend(root)

  original_system = vim.system
  original_env = {
    TMUX = vim.env.TMUX,
    SSH_CONNECTION = vim.env.SSH_CONNECTION,
    SSH_TTY = vim.env.SSH_TTY,
  }

  calls = 0
  vim.system = function()
    calls = calls + 1
    return {
      wait = function() return nil end,
      kill = function() end,
    }
  end

  --- 在 tmux 内（假 socket）且无 SSH 环境变量的前提下执行 fn，返回 pcall 结果
  function with_env(env, fn)
    vim.env.TMUX = '/tmp/vv-utils-fake-tmux-socket,1,0'
    vim.env.SSH_CONNECTION = env.SSH_CONNECTION
    vim.env.SSH_TTY = env.SSH_TTY
    return pcall(fn)
  end
end)

T["同步 wait 返回 nil 按失败兜底不抛错"] = function()
  child.lua_func(function()
    local Remote = require('vv-utils.sys.remote')

    local ok_clients, clients = with_env({}, Remote.tmux_clients)
    local ok_local, local_remote = with_env({}, Remote.is_remote)
    local ok_ssh, ssh_remote = with_env({ SSH_TTY = '/dev/ttys001' }, Remote.is_remote)

    -- 先恢复所有被替换的全局，再断言，避免断言失败时污染后续状态
    vim.system = original_system
    for k, v in pairs(original_env) do vim.env[k] = v end

    assert(calls > 0, '前置条件：打桩的 vim.system 必须被调用')
    assert(ok_clients, 'wait() 返回 nil 时 tmux_clients() 不得抛错：' .. tostring(clients))
    assert(clients == nil, 'tmux list-clients 失败时 tmux_clients() 应返回 nil（判不出）')
    assert(ok_local, 'wait() 返回 nil 时 is_remote() 不得抛错：' .. tostring(local_remote))
    assert(local_remote == false, '命令全部失败且无 SSH 环境变量时应判为本地')
    assert(ok_ssh, 'wait() 返回 nil 时 is_remote() 不得抛错：' .. tostring(ssh_remote))
    assert(ssh_remote == true, '命令全部失败时应按 SSH_TTY 环境变量兜底判为远程')
  end)
end

return T
