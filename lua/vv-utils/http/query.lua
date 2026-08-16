-- HTTP 查询参数工具：严格按 RFC 3986 query component 规则编码

local M = {}

local function is_unreserved(byte)
  return byte >= 0x30 and byte <= 0x39
    or byte >= 0x41 and byte <= 0x5A
    or byte >= 0x61 and byte <= 0x7A
    or byte == 0x2D
    or byte == 0x2E
    or byte == 0x5F
    or byte == 0x7E
end

local function normalize_component(value)
  local value_type = type(value)
  if value_type == 'string' then return value end
  if value_type == 'number' or value_type == 'boolean' then return tostring(value) end
  error('query component must be a string, number, or boolean')
end

---编码一个 URL query component，仅保留 RFC 3986 unreserved 字符
---@param value string|number|boolean
---@return string
function M.encode_query_component(value)
  value = normalize_component(value)
  return (value:gsub('.', function(character)
    local byte = character:byte()
    if is_unreserved(byte) then return character end
    return ('%%%02X'):format(byte)
  end))
end

---将参数按键名排序后追加到 URL；值为 nil 的字段自然省略
---@param url string
---@param params table<string, string|number|boolean|nil>
---@return string
function M.append_query(url, params)
  assert(type(url) == 'string', 'url must be a string')
  assert(type(params) == 'table', 'params must be a table')

  local keys = {}
  for key, value in pairs(params) do
    if value ~= nil then
      if type(key) ~= 'string' then error('query parameter names must be strings') end
      normalize_component(value)
      keys[#keys + 1] = key
    end
  end

  if #keys == 0 then return url end
  table.sort(keys)

  local query = {}
  for _, key in ipairs(keys) do
    query[#query + 1] = M.encode_query_component(key)
      .. '=' .. M.encode_query_component(params[key])
  end

  local fragment_start = url:find('#', 1, true)
  local base = fragment_start and url:sub(1, fragment_start - 1) or url
  local fragment = fragment_start and url:sub(fragment_start) or ''
  local separator

  if not base:find('?', 1, true) then
    separator = '?'
  elseif base:sub(-1) == '?' or base:sub(-1) == '&' then
    separator = ''
  else
    separator = '&'
  end

  return base .. separator .. table.concat(query, '&') .. fragment
end

return M
