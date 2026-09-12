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

-- Modal 与 tree_panel 共同使用这一行结构，避免换行展开和高亮位置计算产生两套实现

return {}
