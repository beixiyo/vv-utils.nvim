# `vv-utils.prompt`

## 职责

提供锚定某个窗口底部的双行过滤输入框：模块维护输入 buffer、焦点、spinner 和关闭生命周期，宿主维护查询结果、模式与打开策略

## 使用

```lua
local prompt = require('vv-utils.prompt').open(win, {
  on_change = function(query) filter(query) end,
  on_accept = function() end,
  on_cancel = function() reset() end,
})
```

`open(anchor_win, opts)` 返回 handle：`close()` 关闭，`redraw()` 重绘，`set_busy(boolean)` 推送 loading 状态，`set_status(text)` 更新状态文本。`on_change` 接收防抖后的查询并且必填；`on_accept`、`on_cancel` 定义确认与取消；可选 `on_input`、`on_navigate`、`on_open_in`、`get_status`

`debounce` 默认 30ms，可为数字或动态函数。提供 `get_mode`、`mode_display`、`on_cycle_mode` 时会渲染模式 badge；spinner 帧动画始终由 `set_busy` 驱动，`spinner` 只用于自定义 `frames` / `interval_ms`：非 nil 时必须是表（`false` 等非表值会抛错，不表示禁用），`spinner.interval_ms` 须为 >= 1 的整数、`spinner.frames` 须为非空字符串列表，规则与 `loading.validate_frame_opts` 相同，非法值在 `open` 时即抛错，不创建浮窗；提供 `completion` 时会挂接 `vv-utils.completion` descriptor

模块不筛选列表、不保存查询，也不选择如何处理 `<C-n>`/`<C-p>` 的结果，避免把宿主业务固定进共享 UI
