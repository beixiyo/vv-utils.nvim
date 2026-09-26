-- 通用持久状态的磁盘仓库
--
-- 每次写入都在固定 sibling lock 保护下重新读取磁盘，只修改目标
-- namespace/key/field，再通过 vv-utils.fs 原子替换 JSON 文件

local Fs = require('vv-utils.fs')
local Lock = require('vv-utils.state.lock')

local M = {}

local VERSION = 1

---@class VVStateStore
---@field path string
---@field lock_opts VVStateLockOptions
local Store = {}
Store.__index = Store

---@return string
function M.default_path()
  return vim.fs.joinpath(vim.fn.stdpath('state'), 'vv-utils', 'state.json')
end

---@return table
local function empty_data()
  return {
    version = VERSION,
    entries = {},
  }
end

---@param self VVStateStore
---@param message string
local function warn(self, message)
  vim.notify('vv-utils.state: ' .. message, vim.log.levels.WARN)
end

---@param self VVStateStore
---@return table data
---@return boolean writable
---@return string? error_message
local function read_data(self)
  local ok, decoded = pcall(Fs.load_json, self.path, { strict = true })
  if not ok then
    warn(self, 'failed to read ' .. self.path .. ': ' .. tostring(decoded))
    return empty_data(), false, tostring(decoded)
  end

  if vim.tbl_isempty(decoded) then return empty_data(), true end
  if decoded.version ~= VERSION or type(decoded.entries) ~= 'table' then
    warn(self, 'ignoring invalid state file: ' .. self.path)
    return empty_data(), false, 'invalid state file'
  end

  return decoded, true
end

---@param self VVStateStore
---@param data table
---@return boolean
---@return string? error_message
-- fsync = false：状态文件保存的是 UI 偏好（面板宽度、打开意图等）。rename 已保证
-- 读者永远看到完整的旧值或新值，断电丢一次窗口宽度无所谓，不值得为它在每次
-- set() 上付 macOS F_FULLSYNC 的代价
local function save_data(self, data)
  local ok, error_message = pcall(Fs.save_json, self.path, data, { mode = 384, fsync = false })
  if not ok then
    warn(self, 'failed to save ' .. self.path .. ': ' .. tostring(error_message))
    return false, tostring(error_message)
  end
  return true
end

-- The callback is deliberately synchronous: the lock remains held until it
-- returns. It must not yield or re-enter a mutation on this store.
---@param self VVStateStore
---@param callback fun(): any, any?, any?
---@return any
---@return any?
---@return any?
local function with_lock(self, callback)
  local lock, lock_error = Lock.acquire(self.path, self.lock_opts)
  if not lock then
    warn(self, lock_error)
    return false, nil, lock_error
  end

  local callback_ok, first, second, third = xpcall(callback, debug.traceback)
  local released, release_error = lock:release()
  if not released then warn(self, release_error) end

  if not callback_ok then error(first) end
  if not released then return false, nil, release_error end
  return first, second, third
end

---@param opts? { path?: string, lock_timeout_ms?: integer, lock_stale_ms?: integer, lock_retry_ms?: integer }
---@return VVStateStore
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    path = Fs.realpath(opts.path or M.default_path()),
    lock_opts = {
      timeout_ms = opts.lock_timeout_ms,
      stale_ms = opts.lock_stale_ms,
      retry_ms = opts.lock_retry_ms,
    },
  }, Store)
end

---@return table
function Store:read()
  local data = read_data(self)
  return data
end

---@param namespace string
---@param key string
---@param field string
---@param value any
---@return boolean
function Store:set(namespace, key, field, value)
  local ok = with_lock(self, function()
    local data, writable, error_message = read_data(self)
    if not writable then return false, error_message end

    local namespace_state = type(data.entries[namespace]) == 'table'
        and data.entries[namespace] or {}
    local key_state = type(namespace_state[key]) == 'table' and namespace_state[key] or {}

    -- 值没变就不写盘：set() 被大量用在「打开面板时记一下当前状态」这类幂等路径上，
    -- 重复写入除了 IO 没有任何效果
    if vim.deep_equal(key_state[field], value) then return true end

    key_state[field] = vim.deepcopy(value)
    namespace_state[key] = key_state
    data.entries[namespace] = namespace_state

    return save_data(self, data)
  end)
  return ok
end

---@param namespace string
---@param key string
---@param field string
---@return boolean
function Store:remove(namespace, key, field)
  local ok = with_lock(self, function()
    local data, writable, error_message = read_data(self)
    if not writable then return false, error_message end

    local namespace_state = data.entries[namespace]
    local key_state = namespace_state and namespace_state[key]
    if type(namespace_state) ~= 'table'
        or type(key_state) ~= 'table'
        or key_state[field] == nil
    then
      return true
    end

    key_state[field] = nil
    if vim.tbl_isempty(key_state) then namespace_state[key] = nil end
    if vim.tbl_isempty(namespace_state) then data.entries[namespace] = nil end

    return save_data(self, data)
  end)
  return ok
end

---@param namespace string
---@param key string
---@param field string
---@param expected any
---@param value any?
---@return boolean updated
---@return any? current
---@return string? error_message
function Store:compare_and_set(namespace, key, field, expected, value)
  return with_lock(self, function()
    local data, writable, error_message = read_data(self)
    if not writable then return false, nil, error_message end

    local namespace_state = type(data.entries[namespace]) == 'table'
        and data.entries[namespace] or nil
    local key_state = namespace_state and type(namespace_state[key]) == 'table'
        and namespace_state[key] or nil
    local current
    if key_state then current = key_state[field] end
    if not vim.deep_equal(current, expected) then
      return false, vim.deepcopy(current)
    end

    if value == nil then
      if key_state then key_state[field] = nil end
      if key_state and vim.tbl_isempty(key_state) then namespace_state[key] = nil end
      if namespace_state and vim.tbl_isempty(namespace_state) then data.entries[namespace] = nil end
    else
      namespace_state = namespace_state or {}
      key_state = key_state or {}
      key_state[field] = vim.deepcopy(value)
      namespace_state[key] = key_state
      data.entries[namespace] = namespace_state
    end

    local saved, save_error = save_data(self, data)
    if not saved then return false, nil, save_error end
    return true, vim.deepcopy(value)
  end)
end

return M
