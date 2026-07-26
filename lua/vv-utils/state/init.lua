-- 命名空间化的通用持久状态
--
-- register(plugin_id, key_id) 返回一个字段容器，所有容器默认共享
-- stdpath('state')/vv-utils/state.json，同时通过两级 ID 避免插件间冲突

local Store = require('vv-utils.state.store')

local M = {}

---@class VVStateRegisterOptions
---@field path? string  自定义状态文件，主要用于测试或隔离环境 @default stdpath('state')/vv-utils/state.json

---@class VVStateHandle
---@field namespace string
---@field key string
---@field store VVStateStore
local Handle = {}
Handle.__index = Handle

---@param value any
---@param label string
local function validate_id(value, label)
  assert(type(value) == 'string' and value:match('^[%w][%w._-]*$'),
    label .. ' must use letters, numbers, dots, underscores, or hyphens')
end

---@param field string
local function validate_field(field)
  validate_id(field, 'state field')
end

---@param plugin_id string
---@param key_id string
---@param opts? VVStateRegisterOptions
---@return VVStateHandle
function M.register(plugin_id, key_id, opts)
  validate_id(plugin_id, 'state plugin id')
  validate_id(key_id, 'state key id')

  return setmetatable({
    namespace = plugin_id,
    key = key_id,
    store = Store.new(opts),
  }, Handle)
end

---@return string
function M.default_path()
  return Store.default_path()
end

---@param field string
---@param default? any
---@return any
function Handle:get(field, default)
  validate_field(field)

  local data = self.store:read()
  local namespace_state = data.entries[self.namespace]
  local key_state = namespace_state and namespace_state[self.key]
  local value = key_state and key_state[field]
  if value == nil then return vim.deepcopy(default) end
  return vim.deepcopy(value)
end

---@param field string
---@param value any
---@return boolean
function Handle:set(field, value)
  validate_field(field)
  assert(value ~= nil, 'state value must not be nil; use remove()')

  local ok, error = pcall(vim.json.encode, value)
  assert(ok, 'state value must be JSON-serializable: ' .. tostring(error))
  return self.store:set(self.namespace, self.key, field, value)
end

---@param field string
---@return boolean
function Handle:remove(field)
  validate_field(field)
  return self.store:remove(self.namespace, self.key, field)
end

return M
