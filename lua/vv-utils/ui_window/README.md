# `vv-utils.ui_window`

集中管理 UI buffer 的窗口 chrome，并保留恢复所需的原窗口选项。`hide_chrome(win, overrides?)` 隐藏行号、signcolumn 等，`show_chrome(win)` 恢复；`DEFAULT_OPTS` 是默认隐藏集合

## 使用

```lua
local window = require('vv-utils.ui_window')
window.hide_chrome(win, { number = false, relativenumber = false })
```

`ensure_unique_buffer_window(tab, buf, preferred?)` 确保一个 tab 中只剩一个显示该 buffer 的窗口，适合侧栏复用。`hide_chrome_until_buf_wiped(win, buf, overrides?)` 将恢复绑定到 buffer 删除生命周期

模块只管窗口选项与重复窗口，不创建 buffer、选择布局或决定窗口何时关闭
