-- vv-utils.exec 通用基元：可执行性、argv 组合与向上项目根查找

local M = {}

local function has_path_separator(command)
  return command:find('/', 1, true) or command:find('\\', 1, true)
end

local function is_absolute(command)
  return command:match('^/') or command:match('^%a:[/\\]')
end

---@param command string
---@param cwd? string
---@return string
function M.resolve_command(command, cwd)
  if not cwd or not has_path_separator(command) or is_absolute(command) then
    return command
  end

  if command:sub(1, 2) == '~/' then
    return vim.fn.expand(command)
  end
  return vim.fs.normalize(cwd .. '/' .. command)
end

---@param prefix string[]
---@param cwd? string
---@return string[]
function M.normalize_prefix(prefix, cwd)
  local normalized = vim.deepcopy(prefix)
  if normalized[1] then
    normalized[1] = M.resolve_command(normalized[1], cwd)
  end
  return normalized
end

---@param prefix string[]
---@param cwd? string
---@return boolean
function M.executable(prefix, cwd)
  local command = prefix[1]
  if not command then return false end

  return vim.fn.executable(M.resolve_command(command, cwd)) == 1
end

---@param prefix string[]
---@param path string
---@return string[]
function M.append_path(prefix, path)
  local command = vim.deepcopy(prefix)
  command[#command + 1] = path
  return command
end

---@param path string
---@param marker string
---@return string?
function M.find_project_root(path, marker)
  local manifest = vim.fs.find(marker, {
    path = vim.fs.dirname(path),
    upward = true,
    type = 'file',
    limit = 1,
  })[1]
  return manifest and vim.fs.dirname(manifest) or nil
end

return M
