# `vv-utils.animate`

## 职责与使用

面向数值的 timer 补间，不绑定窗口或渲染媒介

```lua
local animate = require('vv-utils.animate')
animate.add(0, 100, function(value, ctx)
  render(value)
  if ctx.done then finish() end
end, { id = 'panel-width', duration = 180, easing = 'outCubic' })
```

`add(from, to, cb, opts?)` 返回动画 ID；相同 `opts.id` 会停止旧动画。`del(id)` 取消指定动画。`duration` 可为毫秒数或 `{ step?, total? }`，`int` 决定是否取整；`easing` 可为内置名或自定义函数，内置集合在 `easing` 中

回调上下文包含上帧值 `prev` 与结束标识 `done`。模块只调度数值，不负责窗口有效性、资源所有权或渲染后的清理
