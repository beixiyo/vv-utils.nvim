-- vv-utils.ui_columns 排版决策：在单栏堆叠（stack）与并排分栏（split）之间选择
--
-- 流程：stack 放得下 → fits；分栏宽度不足 → narrow；分栏更矮 → split；否则 no_gain
-- stack 高度按调用方用 wrap 窗口直接显示原文估算（text_height，逐逻辑行累加），
-- split 高度取 compose 的真实合成结果

local Compose = require('vv-utils.ui_columns.compose')
local Wrap = require('vv-utils.ui_columns.wrap')

local M = {}

local dw = vim.fn.strdisplaywidth

---@param section string|VVColumnsSection
---@return string
local function section_text(section)
  if type(section) == 'string' then return section end
  return section.text
end

---@param sections (string|VVColumnsSection)[]
---@param width integer
---@return integer
local function stacked_height(sections, width)
  local height = 0
  for _, section in ipairs(sections) do
    for _, line in ipairs(vim.split(section_text(section), '\n', { plain = true })) do
      height = height + Wrap.text_height(line, width)
    end
  end
  return height
end

---@param opts { columns: (string|VVColumnsSection)[][], available_width: integer, max_height: integer, stack_width: integer, stack_gap: integer, min_column_width: integer, max_column_width: integer, separator: string, align: 'sections'|'top' }
---@return VVColumnsDecision
function M.decide(opts)
  local count = #opts.columns

  local stack_height = opts.stack_gap * (count - 1)
  for _, sections in ipairs(opts.columns) do
    stack_height = stack_height + stacked_height(sections, opts.stack_width)
  end

  local stack = {
    mode = 'stack',
    stack_height = stack_height,
    width = opts.stack_width,
    height = stack_height,
  }

  if stack_height <= opts.max_height then
    stack.reason = 'fits'
    return stack
  end

  local separator_width = dw(opts.separator)
  local column_width = math.min(
    opts.max_column_width,
    math.floor((opts.available_width - (count - 1) * separator_width) / count)
  )
  stack.column_width = column_width

  if column_width < opts.min_column_width then
    stack.reason = 'narrow'
    return stack
  end

  local columns, widths = {}, {}
  for index, sections in ipairs(opts.columns) do
    columns[index] = { sections = sections }
    widths[index] = column_width
  end
  local split_height = Compose.compose({
    columns = columns,
    widths = widths,
    separator = opts.separator,
    separator_hl = '',
    align = opts.align,
    break_on_space = true,
  }).height
  stack.split_height = split_height

  if split_height < stack_height then
    return {
      mode = 'split',
      reason = 'split',
      stack_height = stack_height,
      split_height = split_height,
      column_width = column_width,
      width = column_width * count + separator_width * (count - 1),
      height = split_height,
    }
  end

  stack.reason = 'no_gain'
  return stack
end

return M
