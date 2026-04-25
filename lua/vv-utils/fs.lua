-- 底层文件系统操作：create / delete / rename / copy / move
-- 全部走 vim.uv，失败走 error 向上抛，调用方用 pcall 捕获并 notify

local uv = vim.uv or vim.loop

local M = {}

local function norm(p) return vim.fs.normalize(p) end
local function dirname(p) return vim.fs.dirname(p) end
local function basename(p) return vim.fs.basename(p) end

---@param path string
function M.exists(path)
  return uv.fs_stat(path) ~= nil
end

---@param path string 递归 mkdir -p（0755）
function M.mkdir_p(path)
  path = norm(path)
  if M.exists(path) then return end

  M.mkdir_p(dirname(path))

  local ok, err = uv.fs_mkdir(path, 493) -- 0o755
  if not ok and err and not err:match('EEXIST') then
    error('mkdir failed: ' .. path .. ' — ' .. err)
  end
end

---@param path string 建空文件；parent 自动 mkdir -p
function M.create_file(path)
  path = norm(path)
  if M.exists(path) then error('already exists: ' .. path) end

  M.mkdir_p(dirname(path))

  local fd, err = uv.fs_open(path, 'w', 420) -- 0o644
  if not fd then error('create failed: ' .. path .. ' — ' .. tostring(err)) end
  uv.fs_close(fd)
end

---@param path string 递归删除
function M.delete(path)
  path = norm(path)
  local st = uv.fs_lstat(path)
  if not st then return end -- 已经没了就算成功

  if st.type == 'directory' then
    local scan = uv.fs_scandir(path)
    while scan do
      local name = uv.fs_scandir_next(scan)
      if not name then break end
      M.delete(path .. '/' .. name)
    end

    local ok, err = uv.fs_rmdir(path)
    if not ok then error('rmdir failed: ' .. path .. ' — ' .. tostring(err)) end
  else
    local ok, err = uv.fs_unlink(path)
    if not ok then error('unlink failed: ' .. path .. ' — ' .. tostring(err)) end
  end
end

---@param src string
---@param dst string
function M.rename(src, dst)
  src = norm(src); dst = norm(dst)

  if src == dst then return end
  if M.exists(dst) then error('target exists: ' .. dst) end

  M.mkdir_p(dirname(dst))

  local ok, err = uv.fs_rename(src, dst)
  if not ok then
    -- 跨分区 fs_rename 可能 EXDEV → 降级 copy+delete
    if err and err:match('EXDEV') then
      M.copy(src, dst)
      M.delete(src)
      return
    end
    error('rename failed: ' .. src .. ' → ' .. dst .. ' — ' .. tostring(err))
  end
end

---@param src string
---@param dst string 递归 copy（目录或文件）
function M.copy(src, dst)
  src = norm(src); dst = norm(dst)
  if src == dst then error('copy src == dst: ' .. src) end

  local st = uv.fs_lstat(src)

  if not st then error('copy source missing: ' .. src) end
  if st.type == 'directory' then
    M.mkdir_p(dst)
    local scan = uv.fs_scandir(src)

    while scan do
      local name = uv.fs_scandir_next(scan)
      if not name then break end
      M.copy(src .. '/' .. name, dst .. '/' .. name)
    end
  else
    M.mkdir_p(dirname(dst))
    local ok, err = uv.fs_copyfile(src, dst, { excl = true })
    if not ok then error('copyfile failed: ' .. src .. ' → ' .. dst .. ' — ' .. tostring(err)) end
  end
end

-- 粘贴冲突时在文件名追加 ' (copy)' / ' (copy 2)'，保留后缀
---@param dst string
---@return string unique
function M.unique_dest(dst)
  dst = norm(dst)
  if not M.exists(dst) then return dst end

  local dir = dirname(dst)
  local base = basename(dst)
  local stem, ext = base:match('^(.+)(%.[^.]+)$')

  if not stem then stem, ext = base, '' end

  for i = 1, 100 do
    local suffix = i == 1 and ' (copy)' or string.format(' (copy %d)', i)
    local cand = dir .. '/' .. stem .. suffix .. ext
    if not M.exists(cand) then return cand end
  end
  error('unique_dest: gave up after 100 attempts for ' .. dst)
end

-- 读整个文件内容。失败 error
---@param path string
---@return string
function M.read_all(path)
  path = norm(path)
  local fd, err = uv.fs_open(path, 'r', 420)
  if not fd then error('open failed: ' .. path .. ' — ' .. tostring(err)) end
  local st = uv.fs_fstat(fd)
  if not st then uv.fs_close(fd); error('fstat failed: ' .. path) end
  local data = uv.fs_read(fd, st.size, 0)
  uv.fs_close(fd)
  return data or ''
end

-- 原子地把整个文件内容写入 path；父目录自动 mkdir_p。失败 error。
-- 先写临时文件再 rename，避免写入中途失败（磁盘满等）导致数据丢失
---@param path string
---@param content string
function M.write_all(path, content)
  path = norm(path)
  M.mkdir_p(dirname(path))

  local tmp = path .. '.tmp'
  local fd, err = uv.fs_open(tmp, 'w', 420)

  if not fd then error('open failed: ' .. tmp .. ' — ' .. tostring(err)) end
  local ok, werr = pcall(uv.fs_write, fd, content, 0)

  uv.fs_close(fd)
  if not ok then
    uv.fs_unlink(tmp)
    error('write failed: ' .. path .. ' — ' .. tostring(werr))
  end

  local rok, rerr = uv.fs_rename(tmp, path)
  if not rok then
    uv.fs_unlink(tmp)
    error('rename failed: ' .. tmp .. ' → ' .. path .. ' — ' .. tostring(rerr))
  end
end

-- 重命名/移动后同步所有指向旧路径的 nvim buffer（避免它们回写已消失的路径）
---@param old string
---@param new string
function M.sync_buffers(old, new)
  old = norm(old)
  new = norm(new)

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name == '' then goto continue end

      local nname = norm(name)
      local target

      if nname == old then
        target = new
      elseif nname:sub(1, #old + 1) == old .. '/' then
        target = new .. nname:sub(#old + 1)
      end

      if target then
        vim.api.nvim_buf_set_name(buf, target)
        -- 打标 lua filetype；不 :e 避免丢 unsaved 状态
        pcall(vim.api.nvim_buf_call, buf, function() vim.cmd('silent! doautocmd BufFilePost') end)
      end
      ::continue::
    end
  end
end

return M
