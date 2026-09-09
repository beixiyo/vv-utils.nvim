-- 通用 UI 行渲染：把 text/chunks 行写入 buffer，并应用语义高亮

require('vv-utils.ui_rows.types')

local M = {}

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
