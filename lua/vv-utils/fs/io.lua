-- 完整文件与 JSON 的读取、原子写入

local operations = require('vv-utils.fs.operations')
local path = require('vv-utils.fs.path')

local uv = vim.uv or vim.loop

local M = {}

local function norm(value) return vim.fs.normalize(value) end
local function dirname(value) return vim.fs.dirname(value) end

---@param file string
---@return string
function M.read_all(file)
  file = norm(file)
  local fd, open_error = uv.fs_open(file, 'r', 420)
  if not fd then error('open failed: ' .. file .. ' — ' .. tostring(open_error)) end

  local stat = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    error('fstat failed: ' .. file)
  end

  local parts = {}
  local total = 0
  while total < stat.size do
    local chunk = uv.fs_read(fd, stat.size - total, total)
    if not chunk or chunk == '' then break end
    parts[#parts + 1] = chunk
    total = total + #chunk
  end

  uv.fs_close(fd)
  return table.concat(parts)
end

-- 同目录临时文件完整写入、fsync 后 rename 覆盖目标
---@class VVFsWriteOptions
---@field mode? integer  新文件权限；已有文件默认保留原权限 @default nil
---@field directory_mode? integer  新建父目录权限；已有目录默认保留原权限 @default 0755

---@param file string
---@param content string
---@param opts? VVFsWriteOptions
function M.write_all(file, content, opts)
  file = norm(file)
  local link = uv.fs_lstat(file)

  if link and link.type == 'link' then
    local real, real_error = uv.fs_realpath(file)
    if not real then error('resolve symlink failed: ' .. file .. ' — ' .. tostring(real_error)) end
    file = norm(real)
  end

  local directory = dirname(file)
  local directory_mode = opts and opts.directory_mode

  if directory_mode ~= nil then
    local function mkdir_p(target)
      target = norm(target)
      if path.exists(target) then return end

      mkdir_p(dirname(target))
      local created, mkdir_error = uv.fs_mkdir(target, directory_mode)
      if not created and mkdir_error and not mkdir_error:match('EEXIST') then
        error('mkdir failed: ' .. target .. ' — ' .. mkdir_error)
      end
    end

    mkdir_p(directory)
  else
    operations.mkdir_p(directory)
  end

  local existing = uv.fs_stat(file)
  local mode = opts and opts.mode or existing and (existing.mode % 4096) or 420
  local stem = string.format('%s.tmp.%s.%s', file, tostring(uv.os_getpid()), tostring(uv.hrtime()))
  local temporary, fd, open_error

  for index = 1, 100 do
    local candidate = stem .. '.' .. index
    fd, open_error = uv.fs_open(candidate, 'wx', mode)
    if fd then
      temporary = candidate
      break
    end
    if not tostring(open_error):match('EEXIST') then break end
  end

  if not fd or not temporary then
    error('open temp failed: ' .. file .. ' — ' .. tostring(open_error))
  end

  local chmod_ok, chmod_error = uv.fs_chmod(temporary, mode)
  if not chmod_ok then
    pcall(uv.fs_close, fd)
    pcall(uv.fs_unlink, temporary)
    error('chmod temp failed: ' .. file .. ' — ' .. tostring(chmod_error))
  end

  local function cleanup()
    if fd then
      pcall(uv.fs_close, fd)
      fd = nil
    end
    if temporary then pcall(uv.fs_unlink, temporary) end
  end

  local offset = 0
  while offset < #content do
    local written, write_error = uv.fs_write(fd, content:sub(offset + 1), offset)
    if not written or written <= 0 then
      cleanup()
      error('write failed: ' .. file .. ' — ' .. tostring(write_error or 'short write'))
    end
    offset = offset + written
  end

  local synced, sync_error = uv.fs_fsync(fd)
  if not synced then
    cleanup()
    error('fsync failed: ' .. file .. ' — ' .. tostring(sync_error))
  end

  local closed, close_error = uv.fs_close(fd)
  fd = nil
  if not closed then
    cleanup()
    error('close failed: ' .. file .. ' — ' .. tostring(close_error))
  end

  local renamed, rename_error = uv.fs_rename(temporary, file)
  if not renamed then
    cleanup()
    error('rename failed: ' .. temporary .. ' → ' .. file .. ' — ' .. tostring(rename_error))
  end
end

---@class VVFsLoadJsonOptions
---@field strict? boolean  解码失败或根节点不是 table 时抛错 @default false

---@param source string 文件路径或 JSON 字符串
---@param opts? VVFsLoadJsonOptions
---@return table
function M.load_json(source, opts)
  local raw = source
  if not source:match('^%s*[%[{]') then
    source = norm(source)
    if not path.exists(source) then return {} end
    raw = M.read_all(source)
  end

  local ok, data = pcall(vim.json.decode, raw)
  if opts and opts.strict and (not ok or type(data) ~= 'table') then
    error('decode json failed: ' .. source .. ' — ' .. tostring(ok and 'root must be an object or array' or data))
  end
  return ok and type(data) == 'table' and data or {}
end

---@param file string JSON 文件完整路径，父目录不存在会自动创建
---@param data table
---@param opts? VVFsWriteOptions
function M.save_json(file, data, opts)
  M.write_all(norm(file), vim.json.encode(data), opts)
end

return M
