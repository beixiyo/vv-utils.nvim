-- vv-utils.ui_columns 类型定义（仅注释，无运行时逻辑）

---一段文字；section 级 hl 覆盖栏级 hl
---@class VVColumnsSection
---@field text string 段落文本，可含 '\n'
---@field hl? string 该段文字片段的高亮组

---一栏内容
---@class VVColumnsColumn
---@field sections (string|VVColumnsSection)[] 按顺序排列的段落
---@field hl? string 整栏默认高亮组

---compose 输出的一条高亮；坐标为 0-based 行与字节列（end_col 不含）
---@class VVColumnsHighlight
---@field row integer
---@field start_col integer
---@field end_col integer
---@field hl string

---@class VVColumnsWrapOpts
---@field break_on_space? boolean 优先在最后一个空白处断开并丢弃断点空白；找不到断点或单词超宽时按字符断 @default true

---@class VVColumnsComposeOpts
---@field columns VVColumnsColumn[] 至少一栏
---@field width integer|integer[] 每栏显示宽度；整数表示各栏同宽，数组长度须等于栏数
---@field separator? string 栏间分隔符 @default ' │ '
---@field separator_hl? string 分隔符高亮组 @default 'FloatBorder'
---@field align? 'sections'|'top' 'sections' 让第 i 段在各栏起始行相同；'top' 各栏独立从顶部排 @default 'sections'
---@field break_on_space? boolean 透传 wrap @default true

---@class VVColumnsComposed
---@field lines string[] 合成后的 buffer 行；非末栏补空格到栏宽，末栏不补尾部空格
---@field highlights VVColumnsHighlight[] 分隔符（每行每个一条）与带 hl 的文字片段（不覆盖补齐空格）
---@field height integer 等于 #lines

---@class VVColumnsDecideOpts
---@field columns (string|VVColumnsSection)[][] 每栏的 sections，与 compose 的 sections 同形
---@field available_width integer 可给内容的最大显示宽度（已扣除边框/边距）
---@field max_height integer 不滚动时允许的最大高度
---@field stack_width integer 单栏堆叠时的显示宽度
---@field stack_gap? integer 堆叠时栏与栏之间的空行数 @default 1
---@field min_column_width? integer 分栏宽度下限，低于则判定 narrow @default 40
---@field max_column_width? integer 分栏宽度上限 @default 80
---@field separator? string 栏间分隔符 @default ' │ '
---@field align? 'sections'|'top' 分栏对齐方式 @default 'sections'

---@alias VVColumnsMode 'stack'|'split'
---@alias VVColumnsReason 'fits'|'narrow'|'split'|'no_gain'

---排版决策结果
---@class VVColumnsDecision
---@field mode VVColumnsMode
---@field reason VVColumnsReason fits：堆叠放得下；narrow：分栏宽度不足；split：分栏更矮；no_gain：分栏不比堆叠矮
---@field stack_height integer 堆叠高度（按 wrap 窗口逐逻辑行计算，含栏间空行）
---@field split_height? integer 分栏合成高度；fits / narrow 时为 nil
---@field column_width? integer 计算出的每栏宽度；fits 时为 nil，narrow 时也给出
---@field width integer split 时为栏宽之和加分隔符宽度，stack 时为 stack_width
---@field height integer 所选模式的高度，未截到 max_height

return {}
