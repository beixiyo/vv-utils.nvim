-- vv-utils.ui_columns 多栏合成：各栏按段折行后逐行拼接，输出 buffer 行与字节区间高亮
--
-- 只产出数据（lines/highlights/height），不建 buffer、不开窗口、不注册高亮组

local Wrap = require('vv-utils.ui_columns.wrap')

local M = {}

local dw = vim.fn.strdisplaywidth

---@alias VVColumnsPiece { text: string, hl?: string }

---把一栏的每一段折成带高亮的片段；section.hl 覆盖栏级 hl
---@param column VVColumnsColumn
---@param width integer
---@param break_on_space boolean
---@return VVColumnsPiece[][]
local function wrap_sections(column, width, break_on_space)
  local result = {}
  for index, section in ipairs(column.sections) do
    local text, hl
    if type(section) == 'string' then
      text, hl = section, column.hl
    else
      text, hl = section.text, section.hl or column.hl
    end

    local pieces = {}
    for piece_index, piece in ipairs(Wrap.wrap(text, width, break_on_space)) do
      pieces[piece_index] = { text = piece, hl = hl }
    end
    result[index] = pieces
  end
  return result
end

---每栏一列片段（rows[col][row]），缺的格子视为空串
---@param wrapped VVColumnsPiece[][][]
---@param align 'sections'|'top'
---@return VVColumnsPiece[][] rows
---@return integer height
local function arrange(wrapped, align)
  local rows = {}
  for col = 1, #wrapped do rows[col] = {} end

  if align == 'top' then
    local height = 0
    for col, sections in ipairs(wrapped) do
      for _, pieces in ipairs(sections) do
        vim.list_extend(rows[col], pieces)
      end
      height = math.max(height, #rows[col])
    end
    return rows, height
  end

  local section_count = 0
  for _, sections in ipairs(wrapped) do
    section_count = math.max(section_count, #sections)
  end

  local height = 0
  for index = 1, section_count do
    local section_height = 0
    for _, sections in ipairs(wrapped) do
      section_height = math.max(section_height, #(sections[index] or {}))
    end
    for col, sections in ipairs(wrapped) do
      for offset, piece in ipairs(sections[index] or {}) do
        rows[col][height + offset] = piece
      end
    end
    height = height + section_height
  end
  return rows, height
end

---@param opts { columns: VVColumnsColumn[], widths: integer[], separator: string, separator_hl: string, align: 'sections'|'top', break_on_space: boolean }
---@return VVColumnsComposed
function M.compose(opts)
  local wrapped = {}
  for col, column in ipairs(opts.columns) do
    wrapped[col] = wrap_sections(column, opts.widths[col], opts.break_on_space)
  end
  local rows, height = arrange(wrapped, opts.align)

  local separator = opts.separator
  local last_col = #opts.columns
  local lines, highlights = {}, {}

  for row = 1, height do
    local parts, byte = {}, 0
    for col = 1, last_col do
      local piece = rows[col][row]
      local text = piece and piece.text or ''

      if text ~= '' and piece.hl then
        highlights[#highlights + 1] = { row = row - 1, start_col = byte, end_col = byte + #text, hl = piece.hl }
      end
      parts[#parts + 1] = text
      byte = byte + #text

      if col < last_col then
        local pad = string.rep(' ', math.max(0, opts.widths[col] - dw(text)))
        parts[#parts + 1] = pad
        byte = byte + #pad

        if separator ~= '' then
          highlights[#highlights + 1] = {
            row = row - 1,
            start_col = byte,
            end_col = byte + #separator,
            hl = opts.separator_hl,
          }
        end
        parts[#parts + 1] = separator
        byte = byte + #separator
      end
    end
    lines[row] = table.concat(parts)
  end

  return { lines = lines, highlights = highlights, height = height }
end

return M
