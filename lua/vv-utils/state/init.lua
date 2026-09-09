-- 命名空间化的通用持久状态
--
-- register(plugin_id, key_id) 返回一个字段容器，所有容器默认共享
-- stdpath('state')/vv-utils/state.json，同时通过两级 ID 避免插件间冲突

local Store = require('vv-utils.state.store')
local Timer = require('vv-utils.timer')
local Watch = require('vv-utils.state.watch')

local M = {}

---@class VVStateRegisterOptions
---@field path? string  自定义状态文件，主要用于测试或隔离环境 @default stdpath('state')/vv-utils/state.json
---@field lock_timeout_ms? integer 等待写锁的最长时间 @default 5000
---@field lock_stale_ms? integer 崩溃锁允许回收前的最短年龄 @default 30000
---@field lock_retry_ms? integer 竞争写锁时的轮询间隔 @default 10

---@class VVStateHandle
---@field namespace string
---@field key string
---@field store VVStateStore
local Handle = {}
Handle.__index = Handle

---@class VVStateSubscribeOptions
---@field debounce_ms? integer  合并连续文件事件的等待时间 @default 20

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
---@param expected any
---@param value any? nil deletes the field
---@return boolean updated
---@return any? current the value observed under the lock
---@return string? error_message
function Handle:compare_and_set(field, expected, value)
  validate_field(field)

  if value ~= nil then
    local ok, error_message = pcall(vim.json.encode, value)
    assert(ok, 'state value must be JSON-serializable: ' .. tostring(error_message))
  end

  return self.store:compare_and_set(self.namespace, self.key, field, expected, value)
end

---@param field string
---@return boolean
function Handle:remove(field)
  validate_field(field)
  return self.store:remove(self.namespace, self.key, field)
end

---订阅字段的磁盘变化；同值写入不会触发 callback
---@param field string
---@param callback fun(value: any, previous: any)
---@param opts? VVStateSubscribeOptions
---@return fun() unsubscribe 幂等释放文件监听和本订阅的 timer
function Handle:subscribe(field, callback, opts)
  validate_field(field)
  assert(type(callback) == 'function', 'state subscriber must be a function')
  opts = opts or {}

  local debounce_ms = opts.debounce_ms == nil and 20 or opts.debounce_ms
  assert(type(debounce_ms) == 'number' and debounce_ms >= 0 and debounce_ms % 1 == 0,
    'state subscribe debounce_ms must be a non-negative integer')

  local current = self:get(field)
  local active = true
  local check, cancel_check = Timer.debounce(function()
    if not active then return end
    local value = self:get(field)
    if vim.deep_equal(value, current) then return end

    local previous = current
    current = vim.deepcopy(value)
    local ok, error_message = xpcall(function()
      callback(vim.deepcopy(value), vim.deepcopy(previous))
    end, debug.traceback)
    if not ok then
      vim.notify('vv-utils.state: subscriber callback failed: ' .. tostring(error_message), vim.log.levels.ERROR)
    end
  end, debounce_ms)

  -- 先读取 baseline，再挂监听并补一次检查，覆盖监听安装窗口内的写入
  local watch_ok, unsubscribe_watch = pcall(Watch.subscribe, self.store.path, check)
  if not watch_ok then
    active = false
    cancel_check()
    error(unsubscribe_watch)
  end
  check()

  return function()
    if not active then return end
    active = false
    unsubscribe_watch()
    cancel_check()
  end
end

return M
