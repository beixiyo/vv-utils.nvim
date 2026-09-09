-- 状态文件的跨进程独占锁
--
-- 锁文件固定为状态文件的 sibling（<state>.lock），通过 O_EXCL 创建
-- 锁内 callback 必须同步返回；调用方不能在持锁期间 yield 或重新进入同一个
-- 状态写入。进程崩溃留下的锁由后续进程按年龄和 owner pid 回收

local Fs = require('vv-utils.fs')

local uv = vim.uv or vim.loop

local M = {}

local LOCK_MODE = 384 -- 0600
local DEFAULT_TIMEOUT_MS = 5000
local DEFAULT_STALE_MS = 30000
local DEFAULT_RETRY_MS = 10

local sequence = 0

---@class VVStateLockOptions
---@field timeout_ms? integer 等待锁的最长时间 @default 5000
---@field stale_ms? integer 锁文件被视为 stale 前的最短年龄 @default 30000
---@field retry_ms? integer 竞争锁时两次尝试之间的等待时间 @default 10

---@class VVStateLock
---@field path string
---@field token string
---@field released boolean
---@field release_path? string quarantine path retained after a failed release
---@field release_error? string terminal or retryable release error
---@field release_action? 'unlink'|'terminal' next action for a retained quarantine
local Lock = {}
Lock.__index = Lock

---@param value any
---@param default integer
---@param name string
---@return integer
local function normalize_option(value, default, name)
  if value == nil then return default end
  assert(type(value) == 'number' and value >= 0 and value % 1 == 0,
    name .. ' must be a non-negative integer')
  return value
end

---@return integer
local function monotonic_ms()
  return math.floor(uv.hrtime() / 1000000)
end

---@return integer
local function wall_ms()
  if uv.gettimeofday then
    local seconds, microseconds = uv.gettimeofday()
    return seconds * 1000 + math.floor(microseconds / 1000)
  end
  return os.time() * 1000
end

---@param path string
---@return string
local function lock_path(path)
  return path .. '.lock'
end

---@param error_message any
---@param code string
---@return boolean
local function is_error(error_message, code)
  return tostring(error_message):match(code) ~= nil
end

---@param path string
---@return string?
local function read_file(path)
  local fd = uv.fs_open(path, 'r', 384)
  if not fd then return end

  local stat = uv.fs_fstat(fd)
  if not stat then
    pcall(uv.fs_close, fd)
    return
  end

  local content = uv.fs_read(fd, stat.size, 0)
  pcall(uv.fs_close, fd)
  return content
end

---@param content string?
---@return table?
local function decode_owner(content)
  if not content or content == '' then return end

  local ok, owner = pcall(vim.json.decode, content)
  if not ok or type(owner) ~= 'table' then return end
  return owner
end

---@param path string
---@return table?
local function read_owner(path)
  return decode_owner(read_file(path))
end

---@param pid any
---@return boolean?
local function process_alive(pid)
  pid = tonumber(pid)
  if not pid or pid < 1 or type(uv.kill) ~= 'function' then return end

  local result, error_message = uv.kill(pid, 0)
  if result ~= nil then return true end
  if is_error(error_message, 'ESRCH') then return false end
  if is_error(error_message, 'EPERM') then return true end
end

---@param stat table
---@return integer
local function modified_ms(stat)
  return stat.mtime.sec * 1000 + math.floor((stat.mtime.nsec or 0) / 1000000)
end

---@param path string
---@param stale_ms integer
---@param allow_non_file boolean
---@return table?
local function stale_snapshot(path, stale_ms, allow_non_file)
  local stat = uv.fs_stat(path)
  if not stat then return end
  if not allow_non_file and stat.type ~= 'file' then return end
  if wall_ms() - modified_ms(stat) < stale_ms then return end

  local content = stat.type == 'file' and read_file(path) or nil
  local owner = decode_owner(content)
  local alive = owner and process_alive(owner.pid)
  -- A live owner must never be reclaimed solely because its callback is slow.
  -- When pid probing is unavailable, age remains the only portable stale signal.
  if alive == true then return end
  return {
    stat = stat,
    content = content,
  }
end

---@param first table
---@param second table
---@return boolean
local function same_file(first, second)
  if first.type ~= second.type then return false end

  if first.dev ~= nil and first.ino ~= nil
      and second.dev ~= nil and second.ino ~= nil
  then
    return first.dev == second.dev and first.ino == second.ino
  end

  return first.size == second.size
      and first.mtime.sec == second.mtime.sec
      and (first.mtime.nsec or 0) == (second.mtime.nsec or 0)
end

---@param snapshot table
---@param path string
---@return boolean
local function matches_snapshot(snapshot, path)
  local stat = uv.fs_stat(path)
  if not stat or not same_file(snapshot.stat, stat) then return false end
  if snapshot.stat.type ~= 'file' then return true end
  return snapshot.content == read_file(path)
end

---@param fd integer
---@param content string
---@return boolean, string?
local function write_fd(fd, content)
  local offset = 0
  while offset < #content do
    local written, error_message = uv.fs_write(fd, content:sub(offset + 1), offset)
    if not written or written <= 0 then
      return false, error_message or 'short write'
    end
    offset = offset + written
  end
  return true
end

---@param path string
---@param token string
---@return boolean, string?
local function create_lock(path, token)
  local fd, open_error = uv.fs_open(path, 'wx', LOCK_MODE)
  if not fd then return false, open_error end

  local payload = vim.json.encode({
    pid = uv.os_getpid(),
    token = token,
    created_at = wall_ms(),
  })

  local ok, error_message = write_fd(fd, payload)
  if ok then ok, error_message = uv.fs_fsync(fd) end
  local closed, close_error = uv.fs_close(fd)
  if not closed and ok then ok, error_message = false, close_error end

  if not ok then
    pcall(uv.fs_unlink, path)
    return false, error_message
  end

  local chmod_ok, chmod_error = uv.fs_chmod(path, LOCK_MODE)
  if not chmod_ok then
    pcall(uv.fs_unlink, path)
    return false, chmod_error
  end

  return true
end

---@param source string
---@param destination string
---@return boolean
---@return string? error_message
local function restore_no_replace(source, destination)
  local source_stat = uv.fs_stat(source)
  if not source_stat then return false, 'quarantine path is missing: ' .. source end

  -- A hard link publishes the old owner without replacing a destination that
  -- another process may have created while the quarantine was held.
  if source_stat.type == 'file' and type(uv.fs_link) == 'function' then
    local linked, link_error = uv.fs_link(source, destination)
    if not linked then return false, tostring(link_error) end

    local removed, remove_error = uv.fs_unlink(source)
    if removed or is_error(remove_error, 'ENOENT') then return true end
    return false, 'failed to remove quarantine after restore: ' .. tostring(remove_error)
  end

  if uv.fs_lstat(destination) then
    return false, 'restore destination already exists: ' .. destination
  end
  local restored, restore_error = uv.fs_rename(source, destination)
  if restored then return true end
  return false, tostring(restore_error)
end

---@param path string
---@param stale_ms integer
---@param token string
---@return boolean? removed
---@return string? error_message
local function quarantine_stale_reaper(path, stale_ms, token)
  local snapshot = stale_snapshot(path, stale_ms, true)
  if not snapshot then return false end

  -- 先隔离崩溃遗留的 reaper，再由新的 reaper 对主锁做一次持锁复验
  local quarantine = path .. '.stale.' .. token:gsub('[^%w_.-]', '_')
  local moved, move_error = uv.fs_rename(path, quarantine)
  if not moved then
    if is_error(move_error, 'ENOENT') then return true end
    return nil, 'failed to isolate stale state reaper ' .. path .. ': ' .. tostring(move_error)
  end

  if matches_snapshot(snapshot, quarantine) then
    local removed, remove_error = uv.fs_unlink(quarantine)
    if removed or is_error(remove_error, 'ENOENT') then return true end
  end

  -- The path changed between inspection and rename, or the stale entry is an
  -- abnormal object (for example a directory). Never remove it by pathname;
  -- restore the quarantined entry so the owner or caller keeps its object.
  local restored, restore_error = restore_no_replace(quarantine, path)
  if restored then return false end
  return nil, 'failed to restore stale state reaper ' .. path .. ': ' .. tostring(restore_error)
end

---@param sibling string
---@param stale_ms integer
---@param token string
---@return boolean? reclaimed
---@return string? error_message
local function reclaim_stale(sibling, stale_ms, token)
  local snapshot = stale_snapshot(sibling, stale_ms, false)
  if not snapshot then return false end

  local quarantine = sibling .. '.stale.' .. token:gsub('[^%w_.-]', '_')
  local moved, move_error = uv.fs_rename(sibling, quarantine)
  if not moved then
    if is_error(move_error, 'ENOENT') then return true end
    return nil, 'failed to isolate stale state lock ' .. sibling .. ': ' .. tostring(move_error)
  end

  if not matches_snapshot(snapshot, quarantine) then
    local restored, restore_error = restore_no_replace(quarantine, sibling)
    if not restored then
      return nil, 'failed to restore changed state lock ' .. sibling .. ': ' .. tostring(restore_error)
    end
    return false
  end

  local removed, remove_error = uv.fs_unlink(quarantine)
  if removed or is_error(remove_error, 'ENOENT') then return true end

  local restored, restore_error = restore_no_replace(quarantine, sibling)
  if not restored then
    return nil, ('failed to discard stale state lock %s: %s; failed to restore it: %s')
      :format(sibling, tostring(remove_error), tostring(restore_error))
  end
  return nil, 'failed to discard stale state lock ' .. sibling .. ': ' .. tostring(remove_error)
end

---@param sibling string
---@param stale_ms integer
---@param token string
---@return VVStateLock?
---@return string? error_message
local function acquire_reaper(sibling, stale_ms, token)
  local reaper_path = sibling .. '.reap'
  local _, quarantine_error = quarantine_stale_reaper(reaper_path, stale_ms, token)
  if quarantine_error then return nil, quarantine_error end

  local reaper_token = token .. '.reap'
  local created, create_error = create_lock(reaper_path, reaper_token)
  if not created then
    if is_error(create_error, 'EEXIST') then return end
    return nil, 'failed to create state reaper ' .. reaper_path .. ': ' .. tostring(create_error)
  end

  return setmetatable({
    path = reaper_path,
    token = reaper_token,
    released = false,
  }, Lock)
end

---@param path string
---@param opts? VVStateLockOptions
---@return VVStateLock?
---@return string? error_message
function M.acquire(path, opts)
  opts = opts or {}
  local timeout_ms = normalize_option(opts.timeout_ms, DEFAULT_TIMEOUT_MS, 'state lock timeout_ms')
  local stale_ms = normalize_option(opts.stale_ms, DEFAULT_STALE_MS, 'state lock stale_ms')
  local retry_ms = normalize_option(opts.retry_ms, DEFAULT_RETRY_MS, 'state lock retry_ms')
  local sibling = lock_path(Fs.realpath(path))

  local prepared, prepare_error = pcall(Fs.mkdir_p, vim.fs.dirname(sibling))
  if not prepared then
    return nil, 'failed to prepare state lock directory: ' .. tostring(prepare_error)
  end

  sequence = sequence + 1
  local token = ('%d:%d:%d'):format(uv.os_getpid(), uv.hrtime(), sequence)
  local deadline = monotonic_ms() + timeout_ms

  while true do
    -- Main-lock creation and stale recovery share the same reaper gate. This
    -- prevents a normal acquire from creating a replacement while another
    -- process is validating or removing a stale main lock.
    local reaper, reaper_error = acquire_reaper(sibling, stale_ms, token)
    if reaper_error then return nil, reaper_error end

    if reaper then
      local created, create_error = create_lock(sibling, token)
      if not created and is_error(create_error, 'EEXIST') then
        local reclaimed, reclaim_error = reclaim_stale(sibling, stale_ms, token)
        if reclaim_error then
          local released, release_error = reaper:release()
          if not released then
            return nil, tostring(reclaim_error) .. '\n' .. tostring(release_error)
          end
          return nil, reclaim_error
        end
        if reclaimed then created, create_error = create_lock(sibling, token) end
      end

      if created then
        local lock = setmetatable({
          path = sibling,
          token = token,
          released = false,
        }, Lock)
        local released, release_error = reaper:release()
        if released then return lock end

        local lock_released, lock_release_error = lock:release()
        local message = 'failed to release state reaper ' .. sibling .. '.reap: '
          .. tostring(release_error)
        if not lock_released then
          message = message .. '\n' .. tostring(lock_release_error)
        end
        return nil, message
      end

      local released, release_error = reaper:release()
      if not released then
        return nil, 'failed to release state reaper ' .. sibling .. '.reap: '
          .. tostring(release_error)
      end
      if not is_error(create_error, 'EEXIST') then
        return nil, 'failed to create state lock ' .. sibling .. ': ' .. tostring(create_error)
      end
    end

    -- No gate means another owner currently serializes the main lock. The
    -- normal timeout path below remains unchanged.
    local remaining = deadline - monotonic_ms()
    if remaining <= 0 then
      return nil, 'timed out waiting for state lock: ' .. sibling
    end
    if retry_ms > 0 then uv.sleep(math.min(retry_ms, remaining)) end
  end
end

---@param self VVStateLock
---@return boolean
local function release_success(self)
  self.released = true
  self.release_path = nil
  self.release_error = nil
  self.release_action = nil
  return true
end

---@param self VVStateLock
---@param message string
---@param action 'unlink'|'terminal'
---@param release_path string?
---@return boolean
---@return string
local function release_failure(self, message, action, release_path)
  self.released = false
  self.release_error = message
  self.release_action = action
  self.release_path = release_path
  return false, message
end

---@param self VVStateLock
---@return boolean
---@return string? error_message
local function retry_release_quarantine(self)
  if self.release_action ~= 'unlink' or not self.release_path then
    return false, self.release_error
  end

  local quarantine = self.release_path
  local stat = uv.fs_stat(quarantine)
  if not stat then return release_success(self) end
  if stat.type ~= 'file' then
    return release_failure(self, 'state lock ownership changed: ' .. self.path,
      'terminal', quarantine)
  end

  local owner = read_owner(quarantine)
  if not owner or owner.token ~= self.token then
    return release_failure(self, 'state lock ownership changed: ' .. self.path,
      'terminal', quarantine)
  end

  local removed, remove_error = uv.fs_unlink(quarantine)
  if removed or is_error(remove_error, 'ENOENT') then return release_success(self) end
  return release_failure(self, 'failed to release state lock ' .. self.path .. ': '
    .. tostring(remove_error), 'unlink', quarantine)
end

---@param self VVStateLock
---@param reason string
---@param quarantine string
---@return boolean
---@return string? error_message
local function restore_failed_release(self, reason, quarantine)
  local restored, restore_error = restore_no_replace(quarantine, self.path)
  if restored then return release_failure(self, reason, 'terminal', nil) end
  return release_failure(self, reason .. '; failed to restore it: ' .. tostring(restore_error),
    'terminal', quarantine)
end

---@return boolean
---@return string? error_message
function Lock:release()
  if self.released then return true end
  if self.release_error then
    return retry_release_quarantine(self)
  end

  local current_stat = uv.fs_stat(self.path)
  if not current_stat then return release_success(self) end
  if current_stat.type ~= 'file' then
    return release_failure(self, 'state lock ownership could not be verified: ' .. self.path,
      'terminal', nil)
  end

  local quarantine = self.path .. '.release.' .. self.token:gsub('[^%w_.-]', '_')
  local moved, move_error = uv.fs_rename(self.path, quarantine)
  if not moved then
    if is_error(move_error, 'ENOENT') then return release_success(self) end
    return release_failure(self, 'failed to isolate state lock for release ' .. self.path .. ': '
      .. tostring(move_error), 'terminal', nil)
  end

  local quarantined_stat = uv.fs_stat(quarantine)
  if not quarantined_stat or quarantined_stat.type ~= 'file' then
    return restore_failed_release(self,
      'state lock ownership could not be verified: ' .. self.path, quarantine)
  end

  local owner = read_owner(quarantine)
  if not owner then
    return restore_failed_release(self,
      'state lock ownership could not be verified: ' .. self.path, quarantine)
  end
  if owner.token ~= self.token then
    return restore_failed_release(self, 'state lock ownership changed: ' .. self.path, quarantine)
  end

  local removed, remove_error = uv.fs_unlink(quarantine)
  if removed or is_error(remove_error, 'ENOENT') then return release_success(self) end
  return release_failure(self, 'failed to release state lock ' .. self.path .. ': '
    .. tostring(remove_error), 'unlink', quarantine)
end

return M
