-- vv-utils.ui_columns：文字对比排版器
--
-- 把多栏文字（如原文 / 译文）按显示宽度折行、按段对齐，合成为 buffer 行与字节区间高亮，
-- 并在单栏堆叠与并排分栏之间给出排版决策。纯函数：不开窗口、不建 buffer、不注册高亮组，
-- 窗口尺寸、buffer 写入与高亮组定义由调用方负责
--
-- 本文件只负责参数校验与默认值归一化，算法见 wrap / compose / decide

require('vv-utils.ui_columns.types')

local Compose = require('vv-utils.ui_columns.compose')
local Decide = require('vv-utils.ui_columns.decide')
local Wrap = require('vv-utils.ui_columns.wrap')

local M = {}

local PREFIX = 'vv-utils.ui_columns: '
local DEFAULT_SEPARATOR = ' │ '
local DEFAULT_SEPARATOR_HL = 'FloatBorder'
local ALIGNS = { sections = true, top = true }

local function fail(message)
  error(PREFIX .. message, 0)
end

local function is_integer(value)
  return type(value) == 'number' and value == math.floor(value) and value > -math.huge and value < math.huge
end

local function check_positive(name, value)
  if not is_integer(value) or value < 1 then fail(name .. ' must be a positive integer') end
end

local function check_type(name, value, expected)
  if value ~= nil and type(value) ~= expected then fail(('%s must be a %s'):format(name, expected)) end
end

local function check_align(align)
  if align ~= nil and not ALIGNS[align] then fail("align must be 'sections' or 'top'") end
end

---@param name string
---@param sections any
local function check_sections(name, sections)
  if type(sections) ~= 'table' then fail(name .. ' must be a list') end
  for index, section in ipairs(sections) do
    local text = section
    if type(section) == 'table' then
      text = section.text
      check_type(('%s[%d].hl'):format(name, index), section.hl, 'string')
    end
    if type(text) ~= 'string' then
      fail(('%s[%d] must be a string or { text: string }'):format(name, index))
    end
  end
end

---@param columns any
local function check_columns(columns)
  if type(columns) ~= 'table' or #columns == 0 then fail('columns must be a non-empty list') end
end

---单行文本在 wrap=true、nolinebreak 的 width 宽窗口中占的屏幕行数（与 nvim_win_text_height 一致）
---@param text string 单行文本，不含 '\n'
---@param width integer 窗口文本区显示宽度，>= 1
---@return integer
function M.text_height(text, width)
  if type(text) ~= 'string' then fail('text must be a string') end
  if text:find('\n', 1, true) then fail('text must not contain newlines') end
  check_positive('width', width)
  return Wrap.text_height(text, width)
end

---把文本折成显示宽度不超过 width 的片段；先按 '\n' 拆行再逐行折，空串返回 { '' }
---@param text string
---@param width integer
---@param opts? VVColumnsWrapOpts
---@return string[]
function M.wrap(text, width, opts)
  if type(text) ~= 'string' then fail('text must be a string') end
  check_positive('width', width)
  check_type('opts', opts, 'table')
  opts = opts or {}
  check_type('break_on_space', opts.break_on_space, 'boolean')
  return Wrap.wrap(text, width, opts.break_on_space ~= false)
end

---把多栏文字合成为 buffer 行与高亮
---@param opts VVColumnsComposeOpts
---@return VVColumnsComposed
function M.compose(opts)
  if type(opts) ~= 'table' then fail('opts must be a table') end
  local columns = opts.columns
  check_columns(columns)
  for index, column in ipairs(columns) do
    if type(column) ~= 'table' then fail(('columns[%d] must be a table'):format(index)) end
    check_sections(('columns[%d].sections'):format(index), column.sections)
    check_type(('columns[%d].hl'):format(index), column.hl, 'string')
  end

  local widths = {}
  if type(opts.width) == 'table' then
    if #opts.width ~= #columns then fail('width list must have one entry per column') end
    for index, width in ipairs(opts.width) do
      check_positive(('width[%d]'):format(index), width)
      widths[index] = width
    end
  else
    check_positive('width', opts.width)
    for index = 1, #columns do widths[index] = opts.width end
  end

  check_type('separator', opts.separator, 'string')
  check_type('separator_hl', opts.separator_hl, 'string')
  check_align(opts.align)
  check_type('break_on_space', opts.break_on_space, 'boolean')

  return Compose.compose({
    columns = columns,
    widths = widths,
    separator = opts.separator or DEFAULT_SEPARATOR,
    separator_hl = opts.separator_hl or DEFAULT_SEPARATOR_HL,
    align = opts.align or 'sections',
    break_on_space = opts.break_on_space ~= false,
  })
end

---在单栏堆叠与并排分栏之间做排版决策
---@param opts VVColumnsDecideOpts
---@return VVColumnsDecision
function M.decide(opts)
  if type(opts) ~= 'table' then fail('opts must be a table') end
  check_columns(opts.columns)
  for index, sections in ipairs(opts.columns) do
    check_sections(('columns[%d]'):format(index), sections)
  end
  check_positive('available_width', opts.available_width)
  check_positive('max_height', opts.max_height)
  check_positive('stack_width', opts.stack_width)

  local stack_gap = opts.stack_gap or 1
  if not is_integer(stack_gap) or stack_gap < 0 then fail('stack_gap must be a non-negative integer') end
  local min_column_width = opts.min_column_width or 40
  check_positive('min_column_width', min_column_width)
  local max_column_width = opts.max_column_width or 80
  check_positive('max_column_width', max_column_width)
  check_type('separator', opts.separator, 'string')
  check_align(opts.align)

  return Decide.decide({
    columns = opts.columns,
    available_width = opts.available_width,
    max_height = opts.max_height,
    stack_width = opts.stack_width,
    stack_gap = stack_gap,
    min_column_width = min_column_width,
    max_column_width = max_column_width,
    separator = opts.separator or DEFAULT_SEPARATOR,
    align = opts.align or 'sections',
  })
end

return M
