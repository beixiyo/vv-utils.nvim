-- 文件与目录的创建、删除、复制和移动

local path = require('vv-utils.fs.path')

local uv = vim.uv or vim.loop

local M = {}

local function norm(value) return vim.fs.normalize(value) end
local function dirname(value) return vim.fs.dirname(value) end

---@param directory string 递归 mkdir -p（0755）
function M.mkdir_p(directory)
  directory = norm(directory)
  if path.exists(directory) then return end

  M.mkdir_p(dirname(directory))

  local ok, error = uv.fs_mkdir(directory, 493)
  if not ok and error and not error:match('EEXIST') then
    error('mkdir failed: ' .. directory .. ' — ' .. error)
  end
end

---@param file string 建空文件，parent 自动 mkdir -p
function M.create_file(file)
  file = norm(file)
  if path.exists(file) then error('already exists: ' .. file) end

  M.mkdir_p(dirname(file))

  local fd, open_error = uv.fs_open(file, 'w', 420)
  if not fd then error('create failed: ' .. file .. ' — ' .. tostring(open_error)) end
  uv.fs_close(fd)
end

---@param target string 递归删除
function M.delete(target)
  target = norm(target)
  local stat = uv.fs_lstat(target)
  if not stat then return end

  if stat.type == 'directory' then
    local scan = uv.fs_scandir(target)
    while scan do
      local name = uv.fs_scandir_next(scan)
      if not name then break end
      M.delete(target .. '/' .. name)
    end

    local ok, remove_error = uv.fs_rmdir(target)
    if not ok then error('rmdir failed: ' .. target .. ' — ' .. tostring(remove_error)) end
  else
    local ok, unlink_error = uv.fs_unlink(target)
    if not ok then error('unlink failed: ' .. target .. ' — ' .. tostring(unlink_error)) end
  end
end

---@param source string
---@param destination string
function M.rename(source, destination)
  source = norm(source)
  destination = norm(destination)

  if source == destination then return end
  if path.exists(destination) then error('target exists: ' .. destination) end

  M.mkdir_p(dirname(destination))

  local ok, rename_error = uv.fs_rename(source, destination)
  if not ok then
    if rename_error and rename_error:match('EXDEV') then
      M.copy(source, destination)
      M.delete(source)
      return
    end
    error('rename failed: ' .. source .. ' → ' .. destination .. ' — ' .. tostring(rename_error))
  end
end

---@param source string
---@param destination string 递归复制目录或文件
function M.copy(source, destination)
  source = norm(source)
  destination = norm(destination)
  if source == destination then error('copy src == dst: ' .. source) end

  if destination:sub(1, #source + 1) == source .. '/' then
    error('copy: dst 位于 src 子树内，拒绝（会无限递归）: ' .. destination .. ' ⊂ ' .. source)
  end

  local stat = uv.fs_lstat(source)
  if not stat then error('copy source missing: ' .. source) end

  if stat.type == 'directory' then
    M.mkdir_p(destination)
    local scan = uv.fs_scandir(source)

    while scan do
      local name = uv.fs_scandir_next(scan)
      if not name then break end
      M.copy(source .. '/' .. name, destination .. '/' .. name)
    end
  elseif stat.type == 'link' then
    M.mkdir_p(dirname(destination))
    local target, read_error = uv.fs_readlink(source)
    if not target then error('readlink failed: ' .. source .. ' — ' .. tostring(read_error)) end

    local linked, link_error = uv.fs_symlink(target, destination)
    if not linked then
      error('symlink failed: ' .. source .. ' → ' .. destination .. ' — ' .. tostring(link_error))
    end
  else
    M.mkdir_p(dirname(destination))
    local copied, copy_error = uv.fs_copyfile(source, destination, { excl = true })
    if not copied then
      error('copyfile failed: ' .. source .. ' → ' .. destination .. ' — ' .. tostring(copy_error))
    end
  end
end

return M
