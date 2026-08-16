# `vv-utils.process`

统一封装 `vim.system` 的异步生命周期：启动失败、回到 Neovim 主循环、物理取消，以及取消后压制排队中的回调

```lua
local Process = require('vv-utils.process')

local cancel, start_error = Process.start(
  { 'git', '--version' },
  {
    text = true,
    on_raw_exit = function(result)
      -- 进程 raw exit；即使 cancel() 压制了业务 callback 也会执行
    end,
  },
  function(result)
    print(result.stdout)
  end
)

cancel()
```

`start()` 返回幂等取消函数。同步启动失败不会跨异步 API 抛出，而是通过 `start_error` 返回，并在下一轮主循环投递一个 `code = -1` 的兼容结果

`opts.on_raw_exit` 在 `vim.system` 的底层完成通知到达时立即调用，先于主循环中的业务 `callback`；取消只压制业务 callback，不压制 raw-exit 清理。该字段会从传给 `vim.system` 的选项中剥离。启动失败也会以合成的 `code = -1` 结果通知 `on_raw_exit`

本模块只管理单个进程，不决定重试、超时、下载 staging、结果解析或 latest-wins 策略。多请求所有权继续使用 `vv-utils.async`
