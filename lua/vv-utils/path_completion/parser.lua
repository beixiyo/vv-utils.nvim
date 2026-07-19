-- 路径补全语法解析
--
-- 处理 glob 转义、顶层逗号分段和路径文本判断，不访问文件系统

local M = {}

local GLOB_ESCAPE_TARGETS = '[,{}%[%]*?!\\]'

---@param char string?
---@return boolean
local function is_escape_target(char)
  return char ~= nil and char:match(GLOB_ESCAPE_TARGETS) ~= nil
end

---@param path string
---@return boolean
function M.is_absolute(path)
  return path:sub(1, 1) == '/'
    or path:match('^%a:[/\\]') ~= nil
    or path:match('^[/\\][/\\]') ~= nil
end

---@param value string
---@return string
function M.unescape_glob(value)
  local chars = {}
  local index = 1

  while index <= #value do
    local char = value:sub(index, index)
    local next_char = index < #value and value:sub(index + 1, index + 1) or nil
    if char == '\\' and is_escape_target(next_char) then
      chars[#chars + 1] = next_char
      index = index + 2
    elseif char == '\\' then
      chars[#chars + 1] = '/'
      index = index + 1
    else
      chars[#chars + 1] = char
      index = index + 1
    end
  end

  return table.concat(chars)
end

---@param value string
---@return string
function M.escape_glob(value)
  return (value:gsub('([,{}%[%]*?!\\])', '\\%1'))
end

---@param value string
---@return boolean
function M.has_unescaped_glob(value)
  local escaped = false
  for index = 1, #value do
    local char = value:sub(index, index)
    if escaped then
      escaped = false
    elseif char == '\\' and is_escape_target(value:sub(index + 1, index + 1)) then
      escaped = true
    elseif char:match('[{}%[%]*?]') then
      return true
    end
  end
  return false
end

---@param input string
---@param cursor integer 0-based byte offset
---@return integer start_col 0-based byte offset
function M.glob_segment_start(input, cursor)
  local brace_depth = 0
  local in_class = false
  local start = 1
  local index = 1

  while index <= cursor do
    local char = input:sub(index, index)
    local next_char = index < cursor and input:sub(index + 1, index + 1) or nil

    if char == '\\' and is_escape_target(next_char) then
      index = index + 2
    elseif char == '[' and not in_class then
      in_class = true
      index = index + 1
    elseif char == ']' and in_class then
      in_class = false
      index = index + 1
    elseif char == '{' and not in_class then
      brace_depth = brace_depth + 1
      index = index + 1
    elseif char == '}' and not in_class then
      brace_depth = math.max(0, brace_depth - 1)
      index = index + 1
    elseif char == ',' and brace_depth == 0 and not in_class then
      start = index + 1
      index = index + 1
    else
      index = index + 1
    end
  end

  while start <= cursor and input:sub(start, start):match('%s') do
    start = start + 1
  end
  return start - 1
end

---@param value string
---@return string
function M.strip_relative_prefix(value)
  return value:gsub('^%.[/\\]', ''):gsub('[/\\]+$', '')
end

---@param path string
---@return integer
function M.path_depth(path)
  local _, count = path:gsub('[/\\]', '')
  return count
end

---@param path string
---@param suffix string
---@return boolean
function M.ends_with_path(path, suffix)
  if suffix == '' then return true end
  if path == suffix then return true end
  return #path > #suffix and path:sub(-#suffix - 1) == '/' .. suffix
end

return M
