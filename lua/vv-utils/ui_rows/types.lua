-- vv-utils.ui_rows 的通用行类型

---@class VVUIRowsChunk
---@field [1] string
---@field [2]? string|string[] Buffer/virtual text supports stacked groups; statusline requires a single group.

---@class VVUIRowsRow
---@field text? string
---@field hl? string
---@field chunks? VVUIRowsChunk[]
---@field virt_text? VVUIRowsChunk[]
---@field virt_text_pos? 'eol'|'eol_right_align'|'overlay'|'right_align'|'inline' @default 'right_align'

---@class VVUIRowsRendered
---@field text string
---@field highlights table[]
---@field virt_text? VVUIRowsChunk[]
---@field virt_text_pos? 'eol'|'eol_right_align'|'overlay'|'right_align'|'inline'

---@class VVUIRowsTableOptions
---@field gap? integer 列间空格数 @default 2
---@field align? table<integer, 'left'|'right'> 按列号指定对齐；缺省左对齐
---@field max_widths? table<integer, integer> 按列号限制最大显示宽度，超出截断并加省略号

---@class VVUIRowsBarOptions
---@field char? string 已完成段的字符 @default '━'
---@field todo_char? string 剩余段的字符；缺省与 char 相同
---@field done_hl? string @default 'VVBarDone'
---@field todo_hl? string @default 'VVBarTodo'

-- Modal 与 tree_panel 共同使用这一行结构，避免换行展开和高亮位置计算产生两套实现

return {}
