# `vv-utils.ui_peek`

通用内容浮窗：把一段内容行（源码快照）以只读 buffer 展示在源光标附近的浮窗里。模块负责几何与锚点、快照 buffer、语法高亮、落点高亮、键位和窗口生命周期；调用方只决定内容、落点与交互策略（LSP 请求、多结果切换等）

全局单浮窗：新的 `show` 复用窗口并替换内容。快照是 nofile buffer，浮窗不继承全局 `statuscolumn` 等自绘左列，并默认显示原生行号

## 使用

```lua
local peek = require('vv-utils.ui_peek')

peek.setup({
  -- 所有几何/位置/标题维度都支持 number|string|fun(ctx)
  height = function(ctx) return ctx.span + 10 end,
  min_height = function(ctx) return math.max(10, math.floor(ctx.screen.available / 2)) end,
  max_height = function(ctx) return math.floor(ctx.screen.available * 0.75) end,
  min_width = 60,
  max_width = { ratio = 0.8 }, -- 等价于 math.floor(ctx.screen.columns * 0.8)
  hl = { line = 'CursorLine', range = 'MyPeekHl' },
  keys = {
    ['<CR>'] = function() --[[ 确认跳转 ]] end,
    [']p'] = function() --[[ 下一个结果 ]] end,
  },
  -- 底部边框按键提示：只做展示，须与 close_keys / keys 的实际映射保持一致
  hints = {
    { key = '<CR>', desc = 'Jump' },
    { key = ']p', desc = 'Next' },
    { key = 'q', desc = 'Close' },
  },
})

peek.show({
  uri = location.uri,          -- 或 lines = {...} / path = '...'
  range = location.range,      -- LSP range；character 按 encoding 解析
  encoding = 'utf-16',
  title = function(ctx) return ('1/3 · %s'):format(ctx.filetype) end,
  source_win = win,
})

-- 自绘内容：rows 用 ui_rows 行结构（text/hl/chunks/virt_text），不经任何文件
peek.show({
  rows = {
    { chunks = { { 'No implementations', 'DiagnosticWarn' } } },
    { text = 'interface Foo {}', hl = 'Comment', virt_text = { { '2 refs', 'Special' } } },
  },
  range = { start = { line = 1, character = 11 }, ['end'] = { line = 1, character = 14 } },
})
```

## API

| 函数 | 说明 |
|---|---|
| `setup(opts)` | 归一化模块默认配置，重复调用覆盖；类型见 `types.lua` |
| `show(item, override?)` | 展示内容；`override` 覆盖任意 setup 配置（含函数形态），仅本次生效。返回 `{ win, buf, source_win }` 或 `nil, 'empty content'` |
| `close(focus_source?)` | 关闭浮窗并释放快照 buffer；默认焦点回源窗口，之后触发 `on_close` |
| `is_open()` | 浮窗是否仍打开 |
| `current()` | `{ win, buf, source_win }` 或 nil |

默认行为：

- 内容来源三选一：`rows`（自绘 ui_rows 行，自带 chunks/virt_text 高亮）、`lines`（纯文本行）、`uri`/`path`（文件快照，非 file URI 回退 bufload）；显式 `filetype` 可叠加语法高亮
- 锚点：源光标下方优先，空间不足翻上方；`position = fun(ctx)` 可完全接管（editor 相对 0-based）
- 尺寸：`width` / `height` / `min_*` / `max_*` 都接受 `number`、`{ ratio = n }` 或返回二者之一的 `fun(ctx)`。`ratio` 的基准由轴决定：宽度类为 editor 列数（`ctx.screen.columns`），高度类为 editor 可用行数（`ctx.screen.available`），与浮窗 `relative = 'editor'` 一致。它是字段的一种取值而不是独立字段，因此与 `width` / `height` 不存在互斥：`width = { ratio = 0.8 }` 是目标宽度，`max_width = { ratio = 0.8 }` 是宽度上限；最终仍按 `min ≤ 值 ≤ max` 夹取
- 键位：`q` / `<Esc>` 关闭并回源窗口（`close_keys = false` 禁用）；`keys` 附加 buffer-local 键位
- 按键提示：`hints`（默认 `false`）接受 `{ key, desc }[]` 或 `fun(ctx)`（宽高确定后调用），经 [`ui_window.key_hints`](../ui_window/README.md) 渲染到底部边框，`footer_pos` 默认 `'center'`；宽度不足时整条丢弃尾部条目，`VimResized` / `WinResized` 后按实际窗口宽度重算。`show` 的 `override.hints` 整体替换 setup 的列表（不按下标合并）
- footer 与 `loading.win_text`：提示只在内容变化（hints 或截断结果）时写入，因此 `win_text({ slot = 'footer' })` 接管期间的 loading 帧不会被无变化的重算覆盖，stop 后恢复为提示；接管期间若尺寸变化导致提示重写，`win_text` 视为宿主改值，stop 后同样恢复为最新提示
- 源窗口关闭时浮窗一并关闭；函数配置抛错或返回非法类型时回退默认值

## 边界

- 模块只做浮窗机制，不做业务：不发起 LSP 请求，不理解多结果会话；策略由调用方通过函数配置注入
- 快照 buffer 只读；`enter = false` 时不抢焦点，键位需自行提供进入浮窗的途径
