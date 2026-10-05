# `vv-utils.timer`

## 职责与使用

提供可用于输入框和 UI 刷新的 debounce/throttle 包装，等待时间既可固定，也可在每次调用时动态计算

```lua
local debounce = require('vv-utils.timer').debounce(function(query)
  refresh(query)
end, function() return current_delay_ms() end)
```

`debounce(fn, wait)` 在最后一次调用后执行

`throttle(fn, limit, opts?)` 限制连续调用频率：前沿立即执行，窗口内调用默认丢弃，`opts.trailing = true` 时在窗口结束用最后一次参数补执行一次。异步结果只请求一次刷新的场景（如 Git diff 完成后重绘）必须开 trailing。`wait` / `limit` 可以是毫秒整数或返回毫秒整数的函数

计时器只协调回调频率，不替 owner 取消异步请求；关闭 UI 时仍应取消后续工作或用 request scope 守卫回写
