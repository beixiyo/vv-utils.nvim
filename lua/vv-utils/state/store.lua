-- 通用持久状态的磁盘仓库
--
-- 每次写入前重新读取磁盘，只修改目标 namespace/key/field，再通过 vv-utils.fs
-- 原子替换固定 JSON 文件。它降低多个 Neovim 旧快照互相覆盖的概率，但不提供进程锁

local Fs = require('vv-utils.fs')

local M = {}

local VERSION = 1

---@class VVStateStore
---@field path string
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
local function read_data(self)
  local ok, decoded = pcall(Fs.load_json, self.path, { strict = true })
  if not ok then
    warn(self, 'failed to read ' .. self.path .. ': ' .. tostring(decoded))
    return empty_data(), false
  end

  if vim.tbl_isempty(decoded) then return empty_data(), true end
  if decoded.version ~= VERSION or type(decoded.entries) ~= 'table' then
    warn(self, 'ignoring invalid state file: ' .. self.path)
    return empty_data(), false
  end

  return decoded, true
end

---@param opts? { path?: string }
---@return VVStateStore
function M.new(opts)
  return setmetatable({
    path = vim.fs.normalize(opts and opts.path or M.default_path()),
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
  local data, writable = read_data(self)
  if not writable then return false end
  local namespace_state = data.entries[namespace] or {}
  local key_state = namespace_state[key] or {}

  key_state[field] = vim.deepcopy(value)
  namespace_state[key] = key_state
  data.entries[namespace] = namespace_state

  local ok, error = pcall(Fs.save_json, self.path, data, { mode = 384 })
  if not ok then
    warn(self, 'failed to save ' .. self.path .. ': ' .. tostring(error))
    return false
  end

  return true
end

---@param namespace string
---@param key string
---@param field string
---@return boolean
function Store:remove(namespace, key, field)
  local data, writable = read_data(self)
  if not writable then return false end
  local namespace_state = data.entries[namespace]
  local key_state = namespace_state and namespace_state[key]
  if not key_state or key_state[field] == nil then return true end

  key_state[field] = nil
  if vim.tbl_isempty(key_state) then namespace_state[key] = nil end
  if vim.tbl_isempty(namespace_state) then data.entries[namespace] = nil end

  local ok, error = pcall(Fs.save_json, self.path, data, { mode = 384 })
  if not ok then
    warn(self, 'failed to save ' .. self.path .. ': ' .. tostring(error))
    return false
  end

  return true
end

return M
