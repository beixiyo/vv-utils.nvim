-- Tree panel 的公共行渲染器

local M = {}

local function escape_statusline(text)
  return (text or ''):gsub('%%', '%%%%')
end


---@param value VVTreePanelRenderRow|string?
---@return VVTreePanelRenderRow
function M.normalize(value)
  if type(value) == 'string' then return { text = value } end
  return value or { text = '' }
end

--- 将普通渲染行转换为 winbar/statusline 格式
---@param row VVTreePanelRenderRow|string?
---@return string
function M.statusline(row)
  if row == nil then return '' end

  local normalized = M.normalize(row)
  local chunks = normalized.chunks
  if not chunks then chunks = { { normalized.text or '', normalized.hl } } end

  local output = {}
  for _, chunk in ipairs(chunks) do
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
---@param row VVTreePanelRenderRow|string?
function M.set_line(buf, ns, line, row)
  local normalized = M.normalize(row)
  local chunks = normalized.chunks

  if not chunks then chunks = { { normalized.text or '', normalized.hl } } end

  local parts = {}
  local highlights = {}
  local col = 0
  for _, chunk in ipairs(chunks) do
    local text = chunk[1] or ''
    parts[#parts + 1] = text
    if chunk[2] and text ~= '' then
      highlights[#highlights + 1] = {
        col,
        col + #text,
        chunk[2],
      }
    end
    col = col + #text
  end

  vim.api.nvim_buf_set_lines(buf, line, line + 1, false, { table.concat(parts) })
  for _, item in ipairs(highlights) do
    vim.api.nvim_buf_set_extmark(buf, ns, line, item[1], {
      end_col = item[2],
      hl_group = item[3],
    })
  end

  if normalized.virt_text and #normalized.virt_text > 0 then
    vim.api.nvim_buf_set_extmark(buf, ns, line, 0, {
      virt_text = normalized.virt_text,
      virt_text_pos = normalized.virt_text_pos or 'right_align',
    })
  end
end

return M
