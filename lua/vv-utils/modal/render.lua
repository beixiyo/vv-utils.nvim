-- Modal 正文与 footer 的声明式行渲染

local M = {}
local Keys = require('vv-utils.keys')
local UIRows = require('vv-utils.ui_rows')
local BODY_PADDING = '  '

local function chars(text)
  return text:gmatch('[%z\1-\127\194-\244][\128-\191]*')
end

local function display_width(text)
  return vim.fn.strdisplaywidth(text or '')
end

local function widest_char(parts)
  local widest = 1
  for _, part in ipairs(parts) do
    for char in chars(part.text) do widest = math.max(widest, display_width(char)) end
  end
  return widest
end

local function append_mark(marks, row, col, text, hl)
  if hl and text ~= '' then
    marks[#marks + 1] = { row = row, col = col, length = #text, hl = hl }
  end
end

local function normalized_rows(value)
  if value == nil then return {} end
  if type(value) == 'string' then return { value } end
  if type(value) ~= 'table' then error('vv-utils.modal: body must be rows or strings') end
  if value.text ~= nil or value.chunks or value.icon ~= nil or value.virt_text then return { value } end
  return value
end

local function footer_action(action)
  local hint = action.hint
  if hint == nil then hint = action.keys[1] end
  if hint == false or hint == nil then return {} end

  local parts = {}
  if action.icon then parts[#parts + 1] = { text = action.icon, hl = action.hl } end
  if #parts > 0 then parts[#parts + 1] = { text = '  ' } end
  parts[#parts + 1] = { text = Keys.display(hint), hl = action.hl }
  parts[#parts + 1] = { text = '  ' }
  parts[#parts + 1] = { text = action.label, hl = action.hl }
  return parts
end

local function join(parts)
  local result = {}
  for _, part in ipairs(parts) do result[#result + 1] = part.text end
  return table.concat(result)
end

local function append_segment(segments, text, hl)
  if text == '' then return end
  local previous = segments[#segments]
  if previous and previous.hl == hl then
    previous.text = previous.text .. text
  else
    segments[#segments + 1] = { text = text, hl = hl }
  end
end

local function wrap(parts, max_width)
  local lines, current, current_width = {}, {}, 0
  local function flush()
    lines[#lines + 1] = current
    current, current_width = {}, 0
  end

  for _, part in ipairs(parts) do
    for char in chars(part.text) do
      if char == '\n' then
        flush()
      else
        local width = display_width(char)
        if current_width > 0 and current_width + width > max_width then flush() end
        append_segment(current, char, part.hl)
        current_width = current_width + width
      end
    end
  end

  if #current > 0 or #lines == 0 then lines[#lines + 1] = current end
  return lines
end

local function mark_segments(marks, row, segments, col)
  for _, segment in ipairs(segments) do
    append_mark(marks, row, col, segment.text, segment.hl)
    col = col + #segment.text
  end
end

local function visual_rows(line, width)
  return math.max(math.ceil(math.max(display_width(line), 1) / math.max(width, 1)), 1)
end

---@param opts VVModalOptions
---@param body VVModalRow[]
---@return table
function M.build(opts, body)
  local lines, marks = {}, {}
  local function add_row(row)
    row = UIRows.normalize(row)
    local chunks = UIRows.chunks(row)
    local prefix = (#chunks == 1 and chunks[1][1] == '' and not row.icon) and '' or BODY_PADDING
    if row.icon then
      local icon = row.icon .. ' '
      chunks = { { icon, row.icon_hl }, unpack(chunks) }
    end

    for _, physical in ipairs(UIRows.render({
      chunks = chunks,
      virt_text = row.virt_text,
      virt_text_pos = row.virt_text_pos,
    })) do
      local target = #lines
      lines[#lines + 1] = prefix .. physical.text
      for _, highlight in ipairs(physical.highlights) do
        marks[#marks + 1] = {
          row = target,
          col = #prefix + highlight[1],
          length = highlight[2] - highlight[1],
          hl = highlight[3],
        }
      end
      if physical.virt_text and #physical.virt_text > 0 then
        marks[#marks + 1] = {
          row = target,
          col = 0,
          virt_text = physical.virt_text,
          virt_text_pos = physical.virt_text_pos,
        }
      end
    end
  end

  for _, row in ipairs(normalized_rows(body)) do add_row(row) end

  local footer_parts = {}
  for _, action in ipairs(opts.actions) do
    local parts = footer_action(action)
    if #parts > 0 then
      if #footer_parts > 0 then footer_parts[#footer_parts + 1] = { text = '    ' } end
      vim.list_extend(footer_parts, parts)
    end
  end
  local cancel = opts.cancel
  if cancel then
    local parts = footer_action(cancel)
    if #parts > 0 then
      if #footer_parts > 0 then footer_parts[#footer_parts + 1] = { text = '    ' } end
      vim.list_extend(footer_parts, parts)
    end
  end

  local title = tostring(opts.title or '')
  local footer = join(footer_parts)
  local window_opts = opts.window or {}
  local min_width = math.max(1, tonumber(window_opts.min_width) or 44)
  local max_width = tonumber(window_opts.max_width)
  if not max_width then max_width = math.min(math.max((vim.o.columns or 80) - 4, 1), 96) end
  max_width = math.max(1, math.min(max_width, math.max((vim.o.columns or 80) - 4, 1)))
  max_width = math.max(max_width, display_width(BODY_PADDING) + widest_char(footer_parts))
  local width = math.min(min_width, max_width)
  for _, line in ipairs(lines) do width = math.max(width, display_width(line) + 4) end
  width = math.max(width, display_width(title) + 4, display_width(footer) + 4)
  width = math.min(width, max_width)

  local footer_row
  if #footer_parts > 0 then
    lines[#lines + 1] = ''
    local row = #lines
    if display_width(footer) + display_width(BODY_PADDING) <= width then
      local col = math.max(math.floor((width - display_width(footer)) / 2), 0)
      lines[#lines + 1] = string.rep(' ', col) .. footer
      mark_segments(marks, row, footer_parts, col)
    else
      for _, segments in ipairs(wrap(footer_parts, math.max(width - display_width(BODY_PADDING), 1))) do
        local line = join(segments)
        local target = #lines
        lines[#lines + 1] = BODY_PADDING .. line
        mark_segments(marks, target, segments, #BODY_PADDING)
      end
    end
    footer_row = #lines - 1
  end

  local height = 0
  for _, line in ipairs(lines) do height = height + visual_rows(line, width) end
  local max_height = math.max((vim.o.lines or 24) - (window_opts.margin or 4), 1)
  return {
    lines = lines,
    marks = marks,
    width = width,
    height = math.max(1, math.min(height, max_height)),
    footer_row = footer_row,
  }
end

return M
