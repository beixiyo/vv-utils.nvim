-- 终端粘贴路径解析：兼容原始路径、URI 与 shell 转义

local M = {}

local function strip_quotes(value)
  if #value < 2 then return value end
  local first = value:sub(1, 1)
  local last = value:sub(-1)
  if (first == '"' and last == '"') or (first == "'" and last == "'") then
    return value:sub(2, -2)
  end
  return value
end

local function shell_unescape(value)
  return (value:gsub('\\(.)', '%1'))
end

-- 把一个候选字符串规整成可 fs_stat 的绝对路径；非绝对路径返回 nil
---@param value string
---@return string?
local function normalize_candidate(value)
  if value:match('^file://') then
    value = vim.uri_to_fname(value)
  end
  if not value:match('^[/~]') then return nil end
  return (value:gsub('^~', vim.env.HOME or '~'))
end

---@param raw string
---@return string?
local function try_resolve_path(raw)
  raw = raw:gsub('^%s+', ''):gsub('%s+$', '')
  if raw == '' then return nil end

  -- 候选按优先级：
  --   1. 原始路径（Kitty 等原始解码终端，无 shell 转义，可含字面反斜杠）
  --   2. strip_quotes + shell_unescape 后备（Ghostty/Alacritty 等 shell-转义终端）
  -- 逐个 fs_stat，返回首个真实存在的，避免把合法的字面反斜杠误 strip 成错误路径
  local candidates = { raw }

  local unescaped = shell_unescape(strip_quotes(raw))
  if unescaped ~= raw then
    candidates[#candidates + 1] = unescaped
  end

  for _, candidate in ipairs(candidates) do
    local expanded = normalize_candidate(candidate)
    if expanded then
      local stat = vim.uv.fs_stat(expanded)
      if stat then return expanded end
    end
  end

  return nil
end

--- 检测粘贴内容中的文件/目录路径（绝对路径，/ 或 ~ 开头）
--- 所有行都必须是合法路径才返回，任一行不是则返回 nil
---@param lines string[]
---@return string[]?
function M.detect_paths(lines)
  local joined = table.concat(lines, '\n')
  joined = joined:gsub('^%s+', ''):gsub('%s+$', '')
  if joined == '' then return nil end

  local candidates = vim.split(joined, '\n', { trimempty = true })
  if #candidates == 0 then return nil end

  local paths = {}
  for _, raw in ipairs(candidates) do
    local path = try_resolve_path(raw)
    if not path then return nil end
    paths[#paths + 1] = path
  end

  return #paths > 0 and paths or nil
end

return M
