-- vv-utils.exec shebang 解析：从文件首行提取可执行解释器 argv

local M = {}

---@param line string
---@return string[]?, boolean
local function split_words(line)
  local words = {}
  local word = {}
  local in_single = false
  local in_double = false
  local escaped = false
  local has_value = false

  local function push()
    if has_value then
      words[#words + 1] = table.concat(word)
      word = {}
      has_value = false
    end
  end

  for index = 1, #line do
    local char = line:sub(index, index)

    if escaped then
      word[#word + 1] = char
      has_value = true
      escaped = false
    elseif char == '\\' and not in_single then
      escaped = true
      has_value = true
    elseif char == "'" and not in_double then
      in_single = not in_single
      has_value = true
    elseif char == '"' and not in_single then
      in_double = not in_double
      has_value = true
    elseif not in_single and not in_double and char:match('%s') then
      push()
    else
      word[#word + 1] = char
      has_value = true
    end
  end

  if escaped or in_single or in_double then return nil, false end
  push()
  return words, true
end

---@param path string
---@return string[]?
function M.parse(path)
  local file = io.open(path, 'r')
  if not file then return nil end
  local chunk = file:read(512) or ''
  file:close()

  local line = chunk:match('^#!([^\n]*)')
  if not line then return nil end

  local parts = split_words(line)
  if not parts then return nil end

  local first = parts[1]
  if first and (first == 'env' or first:match('/env$')) then
    table.remove(parts, 1)
    if parts[1] == '-S' or parts[1] == '--split-string' then table.remove(parts, 1) end
  end
  return parts[1] and parts or nil
end

return M
