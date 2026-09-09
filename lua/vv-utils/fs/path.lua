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

---路径是否指向目录，跟随软链接
---@param path string
---@return boolean
function M.is_directory(path)
  local stat = uv.fs_stat(path)
  return stat ~= nil and stat.type == 'directory'
end

---目录是否为空，只读取第一个成员
---@param path string
---@return boolean? empty
---@return string? error_message 路径不是目录或无法读取时返回错误
function M.is_dir_empty(path)
  if not M.is_directory(path) then return nil, 'not a directory: ' .. path end

  local handle, error_message = uv.fs_scandir(path)
  if not handle then return nil, tostring(error_message) end
  return uv.fs_scandir_next(handle) == nil
end

local function is_absolute(path)
  return path:sub(1, 1) == '/'
    or path:match('^%a:[/\\]') ~= nil
    or path:match('^\\\\') ~= nil
end

local function append_path(parent, child)
  if child == '' then return parent end
  return vim.fs.joinpath(parent, child)
end

-- `vim.fs.normalize` folds `..` lexically. For a symlink target that is not
-- correct until existing symlink components have been expanded first. Vim's
-- resolver preserves that filesystem order and also handles missing leaves;
-- symlink loops are delegated to the bounded resolver below.
local function resolve_target(path)
  local ok, resolved = pcall(vim.fn.resolve, path)
  if ok and type(resolved) == 'string' and resolved ~= '' then return norm(resolved) end
  return path
end

-- 逐层解析路径，既处理完整路径不存在，也处理叶子 symlink 指向不存在目标
-- `seen` 让 symlink loop 收敛到当前未解析路径，而不是无限递归
---@param path string
---@param seen table<string, boolean>
---@return string
local function resolve(path, seen)
  path = norm(path)

  local real = uv.fs_realpath(path)
  if real then return norm(real) end

  local stat = uv.fs_lstat(path)
  if not stat then
    local parent = dirname(path)
    if parent == path then return path end
    return append_path(resolve(parent, seen), basename(path))
  end

  if stat.type ~= 'link' then return path end
  if seen[path] then return path end
  seen[path] = true

  local target = uv.fs_readlink(path)
  if not target then return path end

  local target_path = is_absolute(target) and target or vim.fs.joinpath(dirname(path), target)
  target_path = resolve_target(target_path)
  return resolve(target_path, seen)
end

-- 把路径解析到真实路径。路径不存在时解析最长存在祖先，再拼回剩余路径段
-- 叶子 symlink 即使指向不存在目标，也会按 symlink 父目录解析相对 target
---@param path string
---@return string
function M.realpath(path)
  if not path or path == '' then return path end
  -- 参数本身也可能包含 symlink/..，必须先按文件系统顺序展开
  local absolute = norm(vim.fn.fnamemodify(resolve_target(path), ':p'))
  return resolve(absolute, {})
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
