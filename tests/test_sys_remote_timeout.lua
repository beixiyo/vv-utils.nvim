-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  root = vim.env.VV_TEST_REPO
  vim.opt.runtimepath:prepend(root)

  original_env = {
    PATH = vim.env.PATH,
    TMUX = vim.env.TMUX,
    SSH_CONNECTION = vim.env.SSH_CONNECTION,
    SSH_TTY = vim.env.SSH_TTY,
  }

  -- 假 ps：忽略 TERM，约 5s 后才退出；用短 sleep 循环，被 SIGKILL 后孤儿 sleep 至多残留 50ms
  fake_dir = vim.fn.tempname()
  vim.fn.mkdir(fake_dir, 'p')
  fake_ps = fake_dir .. '/ps'
  vim.fn.writefile({
    '#!/bin/sh',
    "trap '' TERM",
    'i=0',
    'while [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done',
  }, fake_ps)
  vim.fn.setfperm(fake_ps, 'rwxr-xr-x')

  function fake_ps_alive()
    local out = vim.system({ '/usr/bin/pgrep', '-f', fake_ps }, { env = { PATH = original_env.PATH } }):wait()
    local n = 0
    for _ in (out.stdout or ''):gmatch('%d+') do n = n + 1 end
    return n
  end
end)

T["忽略 SIGTERM 的探测进程按截止回调且无残留"] = function()
  child.lua_func(function()
    -- 不在 tmux：只执行一次 ps；ps 失败时按 SSH_TTY 兜底判为远程
    vim.env.TMUX = nil
    vim.env.SSH_CONNECTION = nil
    vim.env.SSH_TTY = '/dev/ttys001'
    vim.env.PATH = fake_dir .. ':' .. original_env.PATH

    local Remote = require('vv-utils.sys.remote')

    local result, elapsed_ms = nil, nil
    local start = vim.uv.hrtime()
    Remote.is_remote_async(function(remote)
      result = remote
      elapsed_ms = (vim.uv.hrtime() - start) / 1e6
    end)
    vim.wait(1200, function() return result ~= nil end)

    -- 给 SIGKILL 与孤儿 sleep 一点退出时间，再统计残留
    vim.wait(200)
    local alive = fake_ps_alive()

    -- 先恢复全局并清理（旧实现下假 ps 仍在跑），再断言
    for k, v in pairs(original_env) do vim.env[k] = v end
    vim.system({ '/usr/bin/pkill', '-KILL', '-f', fake_ps }):wait()
    vim.fn.delete(fake_dir, 'rf')

    assert(result ~= nil, 'ps 忽略 SIGTERM 时 callback 也必须在约 1.2s 内到达')
    assert(elapsed_ms < 1200, 'callback 到达过晚：' .. tostring(elapsed_ms) .. 'ms')
    assert(result == true, 'ps 超时应按命令失败处理，并按 SSH_TTY 兜底判为远程')
    assert(alive == 0, '超时后假 ps 必须被 SIGKILL 回收，残留进程数：' .. alive)
  end)
end

return T
