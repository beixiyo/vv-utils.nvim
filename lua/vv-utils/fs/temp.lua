-- 临时文件原语：以独占方式创建受限文件并提供幂等批量清理

local uv = vim.uv or vim.loop
local M = {}
local DEFAULT_MODE = 384 -- 0600

local function unlink(path)
  if path then pcall(uv.fs_unlink, path) end
end

---创建临时文件并写入完整内容
---@param content string
---@param opts? { mode?: integer }
---@return string? path
---@return any? error
function M.write(content, opts)
  assert(type(content) == 'string', 'content must be a string')
  local mode = opts and opts.mode or DEFAULT_MODE
  local path = vim.fn.tempname()
  local fd, open_error = uv.fs_open(path, 'wx', mode)
  if not fd then return nil, open_error end

  local offset = 0
  local write_error
  while offset < #content do
    local written
    written, write_error = uv.fs_write(fd, content:sub(offset + 1), offset)
    if not written or written == 0 then break end
    offset = offset + written
  end
  pcall(uv.fs_close, fd)
  if offset < #content then
    unlink(path)
    return nil, write_error
  end

  local chmod_ok, chmod_error = uv.fs_chmod(path, mode)
  if not chmod_ok then
    unlink(path)
    return nil, chmod_error
  end

  return path
end

---创建空临时文件
---@param opts? { mode?: integer }
---@return string? path
---@return any? error
function M.create(opts)
  return M.write('', opts)
end

---幂等删除一组临时文件
---@param paths string[]
function M.cleanup(paths)
  for _, path in ipairs(paths) do unlink(path) end
end

return M
