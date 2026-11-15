# `vv-utils.ui_window`

集中管理 UI buffer 的窗口 chrome，并保留恢复所需的原窗口选项。`hide_chrome(win, overrides?)` 隐藏行号、signcolumn 等，`show_chrome(win)` 恢复；`DEFAULT_OPTS` 是默认隐藏集合

## 使用

```lua
local window = require('vv-utils.ui_window')
window.hide_chrome(win, { number = false, relativenumber = false })
```

`ensure_unique_buffer_window(tab, buf, preferred?)` 确保一个 tab 中只剩一个显示该 buffer 的窗口，适合侧栏复用。`hide_chrome_until_buf_wiped(win, buf, overrides?)` 将恢复绑定到 buffer 删除生命周期

## 居中浮窗

`open_float(buf, opts)` 用已有 buffer 打开居中浮窗，返回 `{ win, buf, close, update, relayout }`

| 选项 | 默认 | 说明 |
|---|---|---|
| `width` / `height` | 必填 | 大于等于 1 为列数／行数，小于 1 为占编辑器的比例，也可以是返回数值的函数 |
| `backdrop` | `false` | 在浮窗下垫一层半透明遮罩压暗其余界面；数字为遮罩的 `'winblend'` |
| `relayout` | `true` | 终端尺寸变化时按原始选项重新居中并约束尺寸，只改几何，不覆盖之后写入的标题与页脚 |
| `zindex` | Neovim 默认 | 浮窗层级，遮罩自动垫在它下面一层 |
| `title` / `footer` / `border` / `margin` / `chrome` / `enter` | | 同名窗口配置与 `hide_chrome` 的覆盖项 |

`update(opts)` 合并新的尺寸、标题或页脚并立即重新布局。自己调用 `nvim_open_win` 的模块用 `backdrop(win, opts?)` 单独加遮罩

遮罩是一个铺满编辑器、不可聚焦、不拦截鼠标的浮窗，filetype 为 `vv-backdrop`，高亮组 `VVBackdrop`；目标窗口关闭时自动清理。终端不支持真彩色或 `Normal` 没有背景色（透明终端）时混合不出压暗效果，此时不创建

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
