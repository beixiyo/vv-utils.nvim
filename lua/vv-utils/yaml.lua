-- 轻量 YAML 解析器（仅支持常见子集：标量、列表、单层映射）
-- 适用于 pnpm-workspace.yaml 等简单配置文件
local M = {}

--- 去除首尾引号和空白
---@param s string
---@return string
local function strip_quotes(s)
  if not s then return '' end
  local inner = s:match("^[\"'](.-)[\"']%s*$")
  return inner or s:match('^%s*(.-)%s*$') or s
end

--- 解析 YAML 字符串
--- 支持：顶层 key-value、列表（`- item`）、带引号的字符串
--- 不支持：嵌套映射、多行字符串、锚点/引用
---@param text string
---@return table|nil
function M.parse(text)
  if not text or text == '' then return nil end

  local result = {}
  local current_key = nil
  local current_list = nil

  for line in text:gmatch('[^\r\n]*') do
    if line:match('^%s*$') or line:match('^%s*#') then
      goto continue
    end

    -- 列表项：`  - value` 或顶层 `- value`
    local item = line:match('^%s*%-%s+(.*)')
    if item and current_key then
      if not current_list then current_list = {} end
      table.insert(current_list, strip_quotes(item))
      goto continue
    end

    -- 遇到新 key，先保存之前的列表
    if current_key and current_list then
      result[current_key] = current_list
      current_list = nil
    end

    -- 顶层 key: value 或 key:
    local key, value = line:match('^([%w_%-]+):%s*(.*)')
    if key then
      value = value:match('^%s*(.-)%s*$')
      if value == '' then
        current_key = key
      else
        result[key] = strip_quotes(value)
        current_key = nil
      end
    end

    ::continue::
  end

  if current_key and current_list then
    result[current_key] = current_list
  end

  return result
end

--- 解析 YAML 文件
---@param filepath string
---@return table|nil
function M.parse_file(filepath)
  local ok, lines = pcall(vim.fn.readfile, filepath)
  if not ok or not lines then return nil end
  return M.parse(table.concat(lines, '\n'))
end

return M
