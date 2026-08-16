-- 输入历史持久化
--
-- 负责 JSON 校验、磁盘最新记录合并，以及 0600 临时文件的原子写入
-- 不提供进程间锁；并发写入只在每次落盘前尽量吸收当时可见的最新记录

local Data = require('vv-utils.history.data')
local Fs = require('vv-utils.fs')

local M = {}

---@class vv-utils.history.StoreOpts
---@field name string
---@field path string
---@field max_entries integer

---@class vv-utils.history.Store
---@field name string
---@field path string
---@field max_entries integer
local Store = {}
Store.__index = Store

---@param name string
---@return string
function M.default_path(name)
  return vim.fs.joinpath(vim.fn.stdpath('state'), name, 'history.json')
end

---@param self vv-utils.history.Store
---@param message string
local function warn(self, message)
  vim.notify(self.name .. ': ' .. message, vim.log.levels.WARN)
end

---@param path string
---@return string?
local function read_file(path)
  local file = io.open(path, 'rb')
  if not file then return nil end

  local content = file:read('*a')
  file:close()
  return content
end

---@param content string?
---@return table<string, string[]>?
local function decode_fields(content)
  if not content or content == '' then return nil end

  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= 'table' or decoded.version ~= 1 or type(decoded.fields) ~= 'table' then
    return nil
  end

  return decoded.fields
end

---@param self vv-utils.history.Store
---@return table<string, string[]>?
local function load_fields(self)
  local content = read_file(self.path)
  if not content or content == '' then return nil end

  local fields = decode_fields(content)
  if not fields then
    warn(self, 'Ignoring an invalid history file: ' .. self.path)
    return nil
  end

  return Data.normalize_fields(fields, self.max_entries)
end

---@param self vv-utils.history.Store
---@param content string
---@return boolean
local function write_history(self, content)
  local ok, write_error = pcall(Fs.write_all, self.path, content, {
    mode = 384, -- 0600
    directory_mode = 448, -- 0700
  })
  if ok then return true end
  warn(self, 'Failed to save history: ' .. tostring(write_error))
  return false
end

---@param opts vv-utils.history.StoreOpts
---@return vv-utils.history.Store
function M.new(opts)
  return setmetatable({
    name = opts.name,
    path = opts.path,
    max_entries = opts.max_entries,
  }, Store)
end

---加载并清洗已有历史；文件不存在或无效时返回 nil
---@return table<string, string[]>?
function Store:load()
  return load_fields(self)
end

---合并磁盘最新记录与本次新增记录，再原子写回
---@param fallback_fields table<string, string[]>  磁盘文件不存在或无效时使用的当前内存快照
---@param records vv-utils.history.Record[]
---@return table<string, string[]>? fields  成功时返回最终稳定记录
function Store:save(fallback_fields, records)
  local fields = load_fields(self) or fallback_fields

  for _, record in ipairs(records) do
    local items = fields[record.field] or {}
    Data.merge_value(items, record.value, self.max_entries)
    fields[record.field] = items
  end

  local ok, encoded = pcall(vim.json.encode, {
    version = 1,
    fields = fields,
  })
  if not ok then
    warn(self, 'Failed to encode history: ' .. tostring(encoded))
    return nil
  end

  if not write_history(self, encoded .. '\n') then return nil end
  return fields
end

return M
