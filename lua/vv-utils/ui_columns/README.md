# `vv-utils.ui_columns`

文字对比排版器：把多栏文字（如原文 / 译文）按显示宽度折行、按段对齐，合成为 buffer 行与字节区间高亮，并在「单栏堆叠」与「并排分栏」之间给出排版决策

定位是**排版器**：全部是纯函数，不开窗口、不建 buffer、不注册高亮组，也不含任何翻译等业务概念。窗口尺寸、buffer 写入、高亮组定义与滚动由调用方负责

约定：宽度一律是显示宽度（`strdisplaywidth`），列偏移一律是字节。输入假定为可打印文本，Tab 不做列相关修正

## API

| 函数 | 说明 |
|---|---|
| `text_height(text, width)` | 单行文本（不含 `\n`）在 `wrap=true`、`nolinebreak`、宽 `width` 的窗口中占的屏幕行数；宽字符放不下行尾剩余宽度时整字换行，与 `nvim_win_text_height` 一致。空串返回 1 |
| `wrap(text, width, opts?)` | 先按 `\n` 拆行再逐行折成显示宽度 `<= width` 的片段。`opts.break_on_space` 默认 `true`：优先在最后一个空白处断开并丢弃断点空白，找不到断点或单词超宽时按字符断；单字符宽于 `width` 时独占一段。空串返回 `{ '' }` |
| `compose(opts)` | 合成多栏，返回 `{ lines, highlights, height }` |
| `decide(opts)` | 返回排版决策 `{ mode, reason, stack_height, split_height?, column_width?, width, height }` |

参数非法时抛出 `vv-utils.ui_columns: ...` 错误。类型见 `types.lua`

### `compose(opts)`

| 字段 | 默认 | 说明 |
|---|---|---|
| `columns` | 必填 | `{ sections = (string\|{ text, hl? })[], hl? }[]`，至少一栏；section 级 `hl` 覆盖栏级 `hl` |
| `width` | 必填 | 每栏显示宽度；整数表示各栏同宽，数组长度须等于栏数 |
| `separator` | `' │ '` | 栏间分隔符 |
| `separator_hl` | `'FloatBorder'` | 分隔符高亮组 |
| `align` | `'sections'` | `'sections'`：第 i 段在各栏起始行相同，段高取各栏最大值，短的补空行，缺的段视为空；`'top'`：各栏独立从顶部排 |
| `break_on_space` | `true` | 透传 `wrap` |

输出：

- `lines`：栏 1 片段 + 空格补齐到栏宽 + 分隔符 + 栏 2 片段 ...，最后一栏不补尾部空格
- `highlights`：`{ row, start_col, end_col, hl }[]`，0-based 行、字节列（`end_col` 不含）；包含每行每个分隔符一条，以及带 `hl` 的文字片段（不覆盖补齐空格）
- `height`：等于 `#lines`

单栏也合法，等价于按段折行顺排，段间不加空行

```lua
local Columns = require('vv-utils.ui_columns')

local result = Columns.compose({
  columns = {
    { sections = { 'alpha beta gamma', 'next left' } },
    { sections = { { text = '你好世界', hl = 'Special' }, '下一段' }, hl = 'String' },
  },
  width = 10,
})
```

```text
row  lines
0    alpha beta │ 你好世界      ← 第 1 段：左栏折 2 行，右栏 1 行
1    gamma      │               ← 右栏补空行
2    next left  │ 下一段        ← 第 2 段在两栏同一行开始
```

`highlights` 包含 3 条 `FloatBorder`（每行一个分隔符）、`{ row = 0, hl = 'Special' }` 覆盖「你好世界」、`{ row = 2, hl = 'String' }` 覆盖「下一段」。调用方写入：

```lua
vim.api.nvim_buf_set_lines(buf, 0, -1, false, result.lines)
for _, item in ipairs(result.highlights) do
  vim.api.nvim_buf_set_extmark(buf, ns, item.row, item.start_col, {
    end_col = item.end_col,
    hl_group = item.hl,
  })
end
```

分栏窗口应关闭 `wrap`（各行已按栏宽折好）

### `decide(opts)`

| 字段 | 默认 | 说明 |
|---|---|---|
| `columns` | 必填 | 每栏的 sections，与 `compose` 的 sections 同形 |
| `available_width` | 必填 | 可给内容的最大显示宽度（已扣除边框 / 边距） |
| `max_height` | 必填 | 不滚动时允许的最大高度 |
| `stack_width` | 必填 | 单栏堆叠时的宽度，由调用方决定 |
| `stack_gap` | `1` | 堆叠时栏与栏之间的空行数 |
| `min_column_width` | `40` | 分栏宽度下限 |
| `max_column_width` | `80` | 分栏宽度上限 |
| `separator` | `' │ '` | 栏间分隔符 |
| `align` | `'sections'` | 分栏对齐方式 |

流程：

1. `stack_height` = 各栏每个逻辑行在 `stack_width` 下的 `text_height` 之和 + `stack_gap × (栏数 - 1)`。堆叠假定调用方用 `wrap=true` 窗口直接显示原文
2. `stack_height <= max_height` → `{ mode = 'stack', reason = 'fits' }`
3. `column_width = min(max_column_width, floor((available_width - (栏数 - 1) × 分隔符宽) / 栏数))`；`< min_column_width` → `{ mode = 'stack', reason = 'narrow' }`（同样给出 `column_width`）
4. `split_height` = `compose` 在 `column_width` 下的高度；比 `stack_height` 小 → `{ mode = 'split', reason = 'split' }`，否则 `{ mode = 'stack', reason = 'no_gain' }`

`width` 在 split 时为栏宽之和加分隔符宽，stack 时为 `stack_width`；`height` 是所选模式的高度，不截到 `max_height`

```lua
-- 20 段原文 + 20 段译文，堆叠高于 max_height
local decision = Columns.decide({
  columns = { originals, translations },
  available_width = 156,
  max_height = 30,
  stack_width = 80,
})
-- { mode = 'split', reason = 'split', column_width = 76, width = 155, ... }

-- 同样内容、available_width = 76：(76 - 3) / 2 = 36 < 40
-- { mode = 'stack', reason = 'narrow', column_width = 36, width = 76, ... }

if decision.mode == 'split' then
  local result = Columns.compose({
    columns = { { sections = originals }, { sections = translations, hl = 'String' } },
    width = decision.column_width,
  })
  -- 调用方按 decision.width / math.min(decision.height, max_height) 开窗并写入 result
end
```
