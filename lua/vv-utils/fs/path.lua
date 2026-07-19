-- 文件系统路径查询与目标命名

local uv = vim.uv or vim.loop

local M = {}

local function norm(path) return vim.fs.normalize(path) end
local function dirname(path) return vim.fs.dirname(path) end
local function basename(path) return vim.fs.basename(path) end

---@param path string
---@return boolean
function M.exists(path)
  -- lstat 不跟随软链，broken symlink 也必须被视为已存在的文件系统条目
  return uv.fs_lstat(path) ~= nil
end

-- 把路径解析到真实路径。路径不存在时解析最长存在祖先，再拼回剩余路径段
---@param path string
---@return string
function M.realpath(path)
  if not path or path == '' then return path end
  local absolute = norm(vim.fn.fnamemodify(path, ':p'))

  local real = uv.fs_realpath(absolute)
  if real then return norm(real) end

  local rest = {}
  local current = absolute:gsub('/+$', '')
  while current ~= '' do
    local parent = dirname(current)
    if parent == current then break end

    local resolved = uv.fs_realpath(parent)
    if resolved then
      table.insert(rest, 1, basename(current))
      local separator = resolved:sub(-1) == '/' and '' or '/'
      return norm(resolved .. separator .. table.concat(rest, '/'))
    end

    table.insert(rest, 1, basename(current))
    current = parent
  end

  return absolute
end

-- 粘贴冲突时在文件名追加 ' (copy)' / ' (copy 2)'，保留后缀
---@param destination string
---@return string
function M.unique_dest(destination)
  destination = norm(destination)
  if not M.exists(destination) then return destination end

  local dir = dirname(destination)
  local base = basename(destination)
  local stem, extension = base:match('^(.+)(%.[^.]+)$')

  if not stem then stem, extension = base, '' end

  for index = 1, 100 do
    local suffix = index == 1 and ' (copy)' or string.format(' (copy %d)', index)
    local candidate = dir .. '/' .. stem .. suffix .. extension
    if not M.exists(candidate) then return candidate end
  end

  error('unique_dest: gave up after 100 attempts for ' .. destination)
end

return M
