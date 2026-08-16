-- HTTP 请求头序列化与响应头解析

local M = {}

---将请求头映射或原始请求头行列表序列化为 curl header 文件内容
---@param headers table<string, string>|string[]
---@return string? content
---@return string? error_message
function M.serialize(headers)
  local lines = {}
  local is_list = #headers > 0

  if is_list then
    for _, line in ipairs(headers) do
      if type(line) ~= 'string' or line == '' or line:find('[\r\n]') then
        return nil, 'headers must contain valid header lines'
      end
      lines[#lines + 1] = line
    end
  else
    for name, value in pairs(headers) do
      if type(name) ~= 'string' or name == '' or name:find('[\r\n:]') then
        return nil, 'headers must contain valid header names'
      end
      if type(value) ~= 'string' or value:find('[\r\n]') then
        return nil, 'headers must contain valid header values'
      end
      lines[#lines + 1] = name .. ': ' .. value
    end
    table.sort(lines)
  end

  return table.concat(lines, '\n') .. (#lines > 0 and '\n' or '')
end

---解析 curl dump-header 输出的最后一个响应头块
---@param raw string
---@return table<string, string>
function M.parse(raw)
  local blocks = {}
  local current

  for line in (raw .. '\n'):gmatch('(.-)\r?\n') do
    local status = line:match('^HTTP/%d+%.?%d*%s+(%d%d%d)')
    if status then
      current = { _status = tonumber(status) }
      blocks[#blocks + 1] = current
    elseif current and line ~= '' then
      local name, value = line:match('^([^:]+):%s*(.*)$')
      if name and value then
        name = name:lower()
        if current[name] then
          current[name] = current[name] .. ', ' .. value
        else
          current[name] = value
        end
      end
    end
  end

  local last = blocks[#blocks] or {}
  last._status = nil
  return last
end

return M
