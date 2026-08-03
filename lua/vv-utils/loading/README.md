# `vv-utils.loading`

提供两种层次的动画：`start(opts)` 在 buffer 指定行渲染 virt_text，并返回可停止 handle；`ticker(opts)` 只调度帧并调用 `on_frame(frame)`，适合宿主已有复合 UI 时自行渲染

## 使用

```lua
local stop = require('vv-utils.loading').start({
  buf = buf, get_row = function() return 1 end,
})
```

`presets` 提供 `braille`、`dots`、`bounce`。`start` 的关键参数为 `buf`、`get_row()`、`frames`、`interval_ms`、`hl`、`prefix`、`virt_text_pos` 与 `hl_mode`；`get_row()` 返回 nil 时该帧跳过

ticker 不拥有任何 UI 资源，也不会替调用方清理 extmark；关闭窗口或销毁 owner 时必须停止对应 handle
