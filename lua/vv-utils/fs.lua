-- 底层文件系统操作：create / delete / rename / copy / move
-- 全部走 vim.uv，失败走 error 向上抛，调用方用 pcall 捕获并 notify

local uv = vim.uv or vim.loop

local M = {}

local function norm(p) return vim.fs.normalize(p) end
local function dirname(p) return vim.fs.dirname(p) end
local function basename(p) return vim.fs.basename(p) end

---@param path string
function M.exists(path)
  -- 用 fs_lstat（不跟随软链），与 M.delete 一致：broken symlink 是真实存在的文件系统条目，
  -- 必须被 rename/create_file/unique_dest 的冲突检查视为「已存在」，否则会静默覆盖软链
  return uv.fs_lstat(path) ~= nil
end

-- 把路径解析到「真实路径」，用于跨来源路径比对（symlink 一致性）
--
-- 必要性：`vim.fs.normalize` / `fnamemodify(':p')` 只做字符串规整，不解析符号链接，
-- 而 Vim 打开符号链接文件后 `nvim_buf_get_name` 返回的是已解析的真实路径。两套口径
-- 在有 symlink 时会得到「同一文件的两种路径串」，直接字符串相等比对会漏命中
--
-- 行为：路径存在 → `uv.fs_realpath`（解析所有中间 symlink）；
--       路径不存在（如已删除、用于父级回溯）→ 解析「最长存在的祖先目录」后拼回剩余段，
--       使「已删文件」与其 buffer name（解析形）仍可对齐；
--       完全无法解析 → 退回 `vim.fs.normalize(fnamemodify(':p'))`，保证总返回字符串
---@param path string
---@return string
function M.realpath(path)
  if not path or path == '' then return path end
  local abs = norm(vim.fn.fnamemodify(path, ':p'))

  local real = uv.fs_realpath(abs)
  if real then return norm(real) end

  -- 路径本身不存在：解析最长存在的祖先，再拼回剩余段
  local rest = {}
  local cur = abs:gsub('/+$', '')
  while cur ~= '' do
    local parent = dirname(cur)
    if parent == cur then break end
    local rp = uv.fs_realpath(parent)
    if rp then
      table.insert(rest, 1, basename(cur))
      local sep = rp:sub(-1) == '/' and '' or '/'
      return norm(rp .. sep .. table.concat(rest, '/'))
    end
    table.insert(rest, 1, basename(cur))
    cur = parent
  end

  return abs
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

  -- 防自包含递归：dst 落在 src 子树内（dst==src 已在上面拦）时，复制目录进自身会无限
  -- 递归 src/dst/dst/... 直到写满磁盘 / 耗尽 inode。这里在创建任何目录前硬拦，保护所有调用方
  if dst:sub(1, #src + 1) == src .. '/' then
    error('copy: dst 位于 src 子树内，拒绝（会无限递归）: ' .. dst .. ' ⊂ ' .. src)
  end

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
  elseif st.type == 'link' then
    -- 软链照原样重建（不跟随）：lstat 已判定为 link，须复制「链接本身」而非其目标内容
    -- 否则 fs_copyfile 会跟随软链——指向目录时报 EISDIR 整树失败，指向文件时把目标字节
    -- 物化成普通文件，跨分区（EXDEV copy+delete 降级）会静默丢失软链语义
    M.mkdir_p(dirname(dst))
    local target, rerr = uv.fs_readlink(src)
    if not target then error('readlink failed: ' .. src .. ' — ' .. tostring(rerr)) end
    local ok, serr = uv.fs_symlink(target, dst)
    if not ok then error('symlink failed: ' .. src .. ' → ' .. dst .. ' — ' .. tostring(serr)) end
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

  -- fs_read 允许短读（>2GB 文件 / 网络 / FUSE / 被信号中断），单次读会静默截断丢文件尾
  -- 循环按已读偏移补读，直到读满 st.size 或遇 EOF（返回空）
  local parts = {}
  local total = 0
  while total < st.size do
    local chunk = uv.fs_read(fd, st.size - total, total)
    if not chunk or chunk == '' then break end -- EOF / 无更多数据
    parts[#parts + 1] = chunk
    total = total + #chunk
  end

  uv.fs_close(fd)
  return table.concat(parts)
end

-- 原子地把整个文件内容写入 path；父目录自动 mkdir_p。失败 error
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
        -- nvim_buf_set_name 可能抛 E95（已存在同名 loaded buffer：幽灵 buffer / 软链重名 / 该名
        -- 之前被打开过等）。用 pcall 兜住，避免异常冒泡中断调用方后续的 UI 刷新/聚焦
        if pcall(vim.api.nvim_buf_set_name, buf, target) then
          -- 打标 lua filetype；不 :e 避免丢 unsaved 状态
          pcall(vim.api.nvim_buf_call, buf, function() vim.cmd('silent! doautocmd BufFilePost') end)
        end
      end
      ::continue::
    end
  end
end

---@param source string 文件路径或 JSON 字符串
---@return table
function M.load_json(source)
  local raw = source
  if not source:match('^%s*[%[{]') then
    source = norm(source)
    if not M.exists(source) then return {} end
    raw = M.read_all(source)
  end
  local ok, data = pcall(vim.json.decode, raw)
  return ok and type(data) == 'table' and data or {}
end

---@param path string JSON 文件完整路径，父目录不存在会自动创建
---@param data table
function M.save_json(path, data)
  path = norm(path)
  M.write_all(path, vim.json.encode(data))
end

return M
