# `vv-utils.ui_window`

集中管理 UI buffer 的窗口 chrome，并保留恢复所需的原窗口选项。`hide_chrome(win, overrides?)` 隐藏行号、signcolumn 等，`show_chrome(win)` 恢复；`DEFAULT_OPTS` 是默认隐藏集合

## 使用

```lua
local window = require('vv-utils.ui_window')
window.hide_chrome(win, { number = false, relativenumber = false })
```

`ensure_unique_buffer_window(tab, buf, preferred?)` 确保一个 tab 中只剩一个显示该 buffer 的窗口，适合侧栏复用。`hide_chrome_until_buf_wiped(win, buf, overrides?)` 将恢复绑定到 buffer 删除生命周期

## 按键提示

`key_hints(hints, opts?)` 把 `{ key, desc }` 列表渲染为可直接写入浮窗 `title` / `footer` 的高亮 chunks。键位经 [`keys.display`](../keys/README.md) 展示（`<CR>` → `↵`），key 用 `VVKeyHint`（default link `Special`），desc、分隔与留白用 `VVKeyHintDesc`（default link `Comment`）

```lua
local chunks = window.key_hints({
  { key = '<CR>', desc = 'Jump' },
  { key = 'q', desc = 'Close' },
}, { max_width = vim.api.nvim_win_get_width(win) })
if chunks then vim.api.nvim_win_set_config(win, { footer = chunks, footer_pos = 'right' }) end
```

| 选项 | 默认 | 说明 |
|---|---|---|
| `max_width` | 不截断 | 可用显示宽度；不足时整条丢弃尾部条目并追加 `…`，绝不截断单个 key |
| `separator` | `'  '` | 条目间分隔 |
| `padding` | `1` | 首尾留白列数 |
| `key_hl` / `desc_hl` | `VVKeyHint` / `VVKeyHintDesc` | 高亮组 |

空列表或一条都放不下时返回 nil（nvim 不接受空 chunk 数组，调用方据此写 `''` 清空）。函数只渲染，不写窗口；何时写入、尺寸变化时重算由调用方负责，[`ui_peek`](../ui_peek/README.md) 的 `hints` 即基于它

模块只管窗口选项与重复窗口，不创建 buffer、选择布局或决定窗口何时关闭
