-- 通用 UI 行渲染：把 text/chunks 行写入 buffer，并应用语义高亮

require('vv-utils.ui_rows.types')

local M = {}

require('vv-utils.hl').register('vv-utils.ui_rows', {
  VVBarDone = { link = 'Constant' },
  VVBarTodo = { link = 'LineNr' },
})

local function escape_statusline(text)
  return (text or ''):gsub('%%', '%%%%')
end

---@param value VVUIRowsRow|string?
---@return VVUIRowsRow
function M.normalize(value)
  if type(value) == 'string' then return { text = value } end
  return value or { text = '' }
end

---@param row VVUIRowsRow|string?
---@return VVUIRowsChunk[]
function M.chunks(row)
  local normalized = M.normalize(row)
  return normalized.chunks or { { normalized.text or '', normalized.hl } }
end

local function append_chunk(line, text, hl)
  if text == '' then return end
  local previous = line[#line]
  if previous and previous[2] == hl then
    previous[1] = previous[1] .. text
  else
    line[#line + 1] = { text, hl }
  end
end

local function split_chunks(chunks)
  local lines = { {} }
  for _, chunk in ipairs(chunks or {}) do
    local text = tostring(chunk[1] or '')
    local hl = chunk[2]
    local start = 1
    while true do
      local newline = text:find('\n', start, true)
      if not newline then
        append_chunk(lines[#lines], text:sub(start), hl)
        break
      end
      append_chunk(lines[#lines], text:sub(start, newline - 1), hl)
      lines[#lines + 1] = {}
      start = newline + 1
    end
  end
  return lines
end

---Expand a row into physical lines and preserve chunk highlights.
---@param row VVUIRowsRow|string?
---@return VVUIRowsRow[]
function M.expand(row)
  local normalized = M.normalize(row)
  local text_lines = split_chunks(M.chunks(normalized))
  local virt_lines = split_chunks(normalized.virt_text)
  local count = math.max(#text_lines, #virt_lines)
  local result = {}

  for index = 1, count do
    local item = { chunks = text_lines[index] or {} }
    local virt_text = virt_lines[index]
    if virt_text and #virt_text > 0 then
      item.virt_text = virt_text
      item.virt_text_pos = normalized.virt_text_pos
    end
    result[index] = item
  end
  return result
end

---Convert a row to buffer text, highlight spans, and virtual text marks.
---@param row VVUIRowsRow|string?
---@return VVUIRowsRendered[]
function M.render(row)
  local result = {}
  for _, physical in ipairs(M.expand(row)) do
    local text_parts = {}
    local highlights = {}
    local col = 0
    for _, chunk in ipairs(physical.chunks or {}) do
      local text = tostring(chunk[1] or '')
      text_parts[#text_parts + 1] = text
      if chunk[2] and text ~= '' then
        highlights[#highlights + 1] = { col, col + #text, chunk[2] }
      end
      col = col + #text
    end
    result[#result + 1] = {
      text = table.concat(text_parts),
      highlights = highlights,
      virt_text = physical.virt_text,
      virt_text_pos = physical.virt_text_pos or 'right_align',
    }
  end
  return result
end

local function apply_rendered_line(buf, ns, line, rendered)
  for _, item in ipairs(rendered.highlights or {}) do
    vim.api.nvim_buf_set_extmark(buf, ns, line, item[1], {
      end_col = item[2],
      hl_group = item[3],
    })
  end
  if rendered.virt_text and #rendered.virt_text > 0 then
    vim.api.nvim_buf_set_extmark(buf, ns, line, 0, {
      virt_text = rendered.virt_text,
      virt_text_pos = rendered.virt_text_pos,
    })
  end
end

---Replace a buffer with already expanded physical rows and apply their marks.
---@param buf integer
---@param ns integer
---@param rendered VVUIRowsRendered[]
function M.set_rendered_lines(buf, ns, rendered)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false,
    vim.tbl_map(function(item) return item.text end, rendered))
  for line, item in ipairs(rendered) do apply_rendered_line(buf, ns, line - 1, item) end
end

---@param chunks VVUIRowsChunk[]
---@return integer width 显示宽度（宽字符与图标按终端实际占位计）
function M.width(chunks)
  local total = 0
  for _, chunk in ipairs(chunks or {}) do
    total = total + vim.fn.strdisplaywidth(tostring(chunk[1] or ''))
  end
  return total
end

---把片段补齐到指定显示宽度，返回新片段；已超宽时原样返回
---@param chunks VVUIRowsChunk[]
---@param width integer
---@param align? 'left'|'right' 内容靠哪一侧 @default 'left'
---@return VVUIRowsChunk[]
function M.pad(chunks, width, align)
  local result = vim.list_slice(chunks or {})
  local gap = width - M.width(result)
  if gap <= 0 then return result end

  local filler = { string.rep(' ', gap) }
  if align == 'right' then table.insert(result, 1, filler) else result[#result + 1] = filler end
  return result
end

---把片段截到指定显示宽度；被截断的一侧换成省略号，不会把宽字符切成半个
---@param chunks VVUIRowsChunk[]
---@param width integer
---@param opts? { side?: 'right'|'left' } 截掉哪一侧；路径这类尾部更重要的内容用 'left' @default { side = 'right' }
---@return VVUIRowsChunk[]
function M.truncate(chunks, width, opts)
  if M.width(chunks) <= width then return vim.list_slice(chunks or {}) end
  if width <= 0 then return {} end

  local from_left = opts and opts.side == 'left'
  local budget, used = width - 1, 0
  local kept = {} ---@type VVUIRowsChunk[] 按保留方向收集，from_left 时为倒序

  local first, last, step = 1, #chunks, 1
  if from_left then first, last, step = #chunks, 1, -1 end

  for index = first, last, step do
    local chunk = chunks[index]
    local text = tostring(chunk[1] or '')
    local chunk_width = vim.fn.strdisplaywidth(text)
    if used + chunk_width <= budget then
      kept[#kept + 1] = { text, chunk[2] }
      used = used + chunk_width
    else
      -- 这个片段放不完整：逐字符保留靠近保留侧的部分，并把省略号接在被截的一侧
      local count = vim.fn.strchars(text)
      local part = ''
      for offset = 0, count - 1 do
        local char = vim.fn.strcharpart(text, from_left and (count - 1 - offset) or offset, 1)
        local char_width = vim.fn.strdisplaywidth(char)
        if used + char_width > budget then break end
        part = from_left and (char .. part) or (part .. char)
        used = used + char_width
      end
      kept[#kept + 1] = { from_left and ('…' .. part) or (part .. '…'), chunk[2] }
      break
    end
  end

  if not from_left then return kept end
  local result = {}
  for index = #kept, 1, -1 do result[#result + 1] = kept[index] end
  return result
end

---按列对齐多行：每行是若干单元格，每个单元格是片段数组或字符串
---
---列宽取该列最宽单元格的显示宽度；最后一列不补齐，避免行尾出现多余空格
---@param rows (VVUIRowsChunk[]|string)[][]
---@param opts? VVUIRowsTableOptions
---@return VVUIRowsChunk[][] lines 每行一个片段数组，可直接作为 row.chunks
function M.table(rows, opts)
  opts = opts or {}
  local gap = string.rep(' ', opts.gap or 2)
  local align = opts.align or {}
  local max_widths = opts.max_widths or {}

  local cells, widths = {}, {}
  for row_index, row in ipairs(rows) do
    cells[row_index] = {}
    for column, cell in ipairs(row) do
      local chunks = type(cell) == 'string' and { { cell } } or cell
      if max_widths[column] then chunks = M.truncate(chunks, max_widths[column]) end
      cells[row_index][column] = chunks
      widths[column] = math.max(widths[column] or 0, M.width(chunks))
    end
  end

  local lines = {}
  for row_index, row in ipairs(cells) do
    local line = {}
    for column, chunks in ipairs(row) do
      local last = column == #row
      local padded = (last and align[column] ~= 'right') and chunks or M.pad(chunks, widths[column], align[column])
      vim.list_extend(line, padded)
      if not last then line[#line + 1] = { gap } end
    end
    lines[row_index] = line
  end
  return lines
end

---水平比例条：已完成段与剩余段各用一种高亮
---@param ratio number 0 到 1，越界时截到边界
---@param width integer 总列数
---@param opts? VVUIRowsBarOptions
---@return VVUIRowsChunk[]
function M.bar(ratio, width, opts)
  opts = opts or {}
  ratio = math.max(0, math.min(1, ratio or 0))
  local done = math.floor(width * ratio + 0.5)
  -- 非零值至少画一格，否则很小的比例会和零无法区分
  if ratio > 0 and done == 0 then done = 1 end

  local char = opts.char or '━'
  local chunks = {}
  if done > 0 then chunks[#chunks + 1] = { string.rep(char, done), opts.done_hl or 'VVBarDone' } end
  if width > done then
    chunks[#chunks + 1] = { string.rep(opts.todo_char or char, width - done), opts.todo_hl or 'VVBarTodo' }
  end
  return chunks
end

---将普通渲染行转换为 winbar/statusline 格式
---@param row VVUIRowsRow|string?
---@return string
function M.statusline(row)
  if row == nil then return '' end

  local output = {}
  for _, chunk in ipairs(M.chunks(row)) do
    local text = escape_statusline(chunk[1])
    if chunk[2] and text ~= '' then
      output[#output + 1] = ('%%#%s#%s%%*'):format(chunk[2], text)
    else
      output[#output + 1] = text
    end
  end
  return table.concat(output)
end

---@param buf integer
---@param ns integer
---@param line integer
---@param row VVUIRowsRow|string?
function M.set_line(buf, ns, line, row)
  local rendered = M.render(row)
  vim.api.nvim_buf_set_lines(buf, line, line + 1, false,
    vim.tbl_map(function(item) return item.text end, rendered))
  for offset, rendered_line in ipairs(rendered) do
    apply_rendered_line(buf, ns, line + offset - 1, rendered_line)
  end
end

return M
