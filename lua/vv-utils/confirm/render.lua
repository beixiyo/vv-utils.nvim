-- 确认框内容渲染：把声明式内容转换为行、语义高亮和居中位置

local M = {}
local BODY_PADDING = '  '
local Keys = require('vv-utils.keys')

local confirm_highlights = {
  info = 'DiagnosticOk',
  warn = 'DiagnosticWarn',
  danger = 'DiagnosticError',
}

local function list(value)
  if value == nil then
    return {}
  end
  if type(value) == 'table' then
    if value.text then return { value } end
    return value
  end
  return { value }
end

---@param value any
---@return string[]
local function split_lines(value)
  local text = tostring(value or '')
  local result = vim.split(text, '\n', { plain = true, trimempty = false })

  for index, line in ipairs(result) do
    -- 回车符会成为详情中的可见字符，并干扰显示宽度计算
    result[index] = line:gsub('\r$', '')
  end

  return #result > 0 and result or { '' }
end

local function message_lines(message)
  local lines = {}

  for _, item in ipairs(list(message)) do
    if type(item) == 'string' then
      for _, text in ipairs(split_lines(item)) do
        lines[#lines + 1] = { text = text, hl = 'Normal' }
      end
    elseif type(item) == 'table' then
      for index, text in ipairs(split_lines(item.text)) do
        lines[#lines + 1] = {
          text = text,
          hl = item.hl or 'Normal',
          icon = index == 1 and item.icon or nil,
          icon_hl = item.icon_hl,
        }
      end
    else
      for _, text in ipairs(split_lines(item)) do
        lines[#lines + 1] = { text = text, hl = 'Normal' }
      end
    end
  end

  return lines
end

local function centered_column(width, text)
  return math.max(math.floor((width - vim.fn.strdisplaywidth(text)) / 2), 0)
end

local function visual_rows(line, width)
  return math.max(math.ceil(math.max(vim.fn.strdisplaywidth(line), 1) / math.max(width, 1)), 1)
end

local function action_parts(icon, hint, label, hl)
  if hint == false then return {} end
  return {
    { text = icon,               hl = hl },
    { text = '  ' },
    { text = Keys.display(hint), hl = hl },
    { text = '  ' },
    { text = label,              hl = hl },
  }
end

local function footer_parts(opts, confirm_icon, confirm_label, cancel_icon, cancel_label, confirm_hl)
  local parts = action_parts(confirm_icon, opts.actions.confirm.hint, confirm_label, confirm_hl)
  local cancel = action_parts(cancel_icon, opts.actions.cancel.hint, cancel_label, 'Comment')

  if #parts > 0 and #cancel > 0 then parts[#parts + 1] = { text = '    ' } end
  vim.list_extend(parts, cancel)

  return parts
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

---@param parts table[]
---@param max_width integer
---@return table[]
local function wrap_footer(parts, max_width)
  max_width = math.max(max_width, 1)
  local lines = {}
  local current = {}
  local current_width = 0

  local function flush()
    lines[#lines + 1] = current
    current = {}
    current_width = 0
  end

  for _, part in ipairs(parts) do
    for char in part.text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
      if char == '\n' then
        flush()
      else
        local char_width = vim.fn.strdisplaywidth(char)
        if current_width > 0 and current_width + char_width > max_width then flush() end
        append_segment(current, char, part.hl)
        current_width = current_width + char_width
      end
    end
  end

  if #current > 0 or #lines == 0 then lines[#lines + 1] = current end
  return lines
end

local function join_segments(segments)
  local text = {}
  for _, segment in ipairs(segments) do text[#text + 1] = segment.text end
  return table.concat(text)
end

local function widest_footer_char(parts)
  local widest = 1
  for _, part in ipairs(parts) do
    for char in part.text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
      widest = math.max(widest, vim.fn.strdisplaywidth(char))
    end
  end
  return widest
end

local function mark_segments(marks, row, segments, base_col)
  local col = base_col

  for _, segment in ipairs(segments) do
    if segment.hl and segment.text ~= '' then
      marks[#marks + 1] = {
        row = row,
        col = col,
        length = #segment.text,
        hl = segment.hl,
      }
    end
    col = col + #segment.text
  end
end

---@param opts VVConfirmOptions
---@return {
--- lines:string[],
--- marks:table[],
--- width:integer,
--- height:integer,
--- footer_row:integer,
--- }
function M.build(opts)
  local title = tostring(opts.title or '')
  local lines = {}
  local marks = {}

  local function add_line(text, hl, icon, icon_hl)
    text = tostring(text or '')
    local prefix = text == '' and '' or BODY_PADDING
    local icon_prefix = icon and icon .. ' ' or ''
    lines[#lines + 1] = prefix .. icon_prefix .. text
    if hl and text ~= '' then
      marks[#marks + 1] = {
        row = #lines - 1,
        col = #prefix + #icon_prefix,
        length = #text,
        hl = hl,
      }
    end
    if icon_hl and icon then
      marks[#marks + 1] = {
        row = #lines - 1,
        col = #prefix,
        length = #icon,
        hl = icon_hl,
      }
    end
  end

  for _, message in ipairs(message_lines(opts.message)) do
    add_line(message.text, message.hl, message.icon, message.icon_hl)
  end

  local details = opts.details or {}
  if #details > 0 and #lines > 0 and lines[#lines] ~= '' then
    add_line('')
  end

  for _, detail in ipairs(details) do
    if detail.separator_before then
      add_line('')
    end
    for _, line in ipairs(split_lines(detail.label)) do
      add_line(line, 'Comment')
    end
    for _, line in ipairs(split_lines(detail.value)) do
      -- 每个物理行都缩进，避免含换行的路径或命令逃出详情区块
      add_line('  ' .. line, detail.hl or 'Directory')
    end
  end

  local confirm_label = tostring(opts.confirm_label or 'Confirm')
  local cancel_label = tostring(opts.cancel_label or 'Cancel')
  local confirm_icon = tostring(opts.confirm_icon or '󰄬')
  local cancel_icon = tostring(opts.cancel_icon or '󰜺')
  local footer_hl = opts.confirm_hl or confirm_highlights[opts.severity or 'info'] or 'DiagnosticOk'
  local parts = footer_parts(opts, confirm_icon, confirm_label, cancel_icon, cancel_label, footer_hl)
  local footer = join_segments(parts)
  local padding_width = vim.fn.strdisplaywidth(BODY_PADDING)
  local minimum_width = padding_width + widest_footer_char(parts)

  local window_opts = opts.window or {}
  local min_width = math.max(1, tonumber(window_opts.min_width) or 44)
  local max_width = tonumber(window_opts.max_width)
  if not max_width then
    max_width = math.min(math.max((vim.o.columns or 80) - 4, 1), 96)
  end
  max_width = math.max(1, math.min(max_width, math.max((vim.o.columns or 80) - 4, 1)))
  -- Every wrapped footer line has BODY_PADDING. Normalize tiny public values so
  -- a single wide glyph plus that padding cannot exceed the window width.
  max_width = math.max(max_width, minimum_width)
  local width = math.min(min_width, max_width)

  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line) + 4)
  end
  width = math.max(width, vim.fn.strdisplaywidth(title) + 4)
  width = math.max(width, vim.fn.strdisplaywidth(footer) + 4)
  width = math.min(width, max_width)

  local footer_row
  if #parts > 0 then
    add_line('')
    local footer_first_row = #lines
    if vim.fn.strdisplaywidth(footer) + padding_width <= width then
      local footer_col = centered_column(width, footer)
      lines[#lines + 1] = string.rep(' ', footer_col) .. footer
      mark_segments(marks, footer_first_row, parts, footer_col)
    else
      for _, segments in ipairs(wrap_footer(parts, width - padding_width)) do
        local line = join_segments(segments)
        local row = #lines
        add_line(line)
        mark_segments(marks, row, segments, #BODY_PADDING)
      end
    end
    footer_row = #lines - 1
  end

  local total_height = 0
  for _, line in ipairs(lines) do
    total_height = total_height + visual_rows(line, width)
  end
  local max_height = math.max((vim.o.lines or 24) - 4, 1)

  return {
    lines = lines,
    marks = marks,
    width = width,
    height = math.max(1, math.min(total_height, max_height)),
    footer_row = footer_row,
  }
end

return M
