-- 异步请求作用域 owner
-- 跟踪 owner epoch、各通道 revision 和在途请求资源

local Request = require('vv-utils.async.request')

---@class vv-utils.async.Scope
---@field private _epoch integer
---@field private _next_id integer
---@field private _disposed boolean
---@field private _cancel_previous boolean
---@field private _active table<integer, vv-utils.async.Request>
---@field private _controls table<vv-utils.async.Request, vv-utils.async.RequestControl>
---@field private _lanes table<vv-utils.async.RequestKey, vv-utils.async.Lane>
local Scope = {}
Scope.__index = Scope

local M = {}

---@class vv-utils.async.Lane
---@field mode vv-utils.async.RequestMode
---@field revision integer
---@field references integer
---@field latest? vv-utils.async.Request

local function active_snapshot(scope)
  local entries = {}

  for _, request in pairs(scope._active) do
    entries[#entries + 1] = {
      request = request,
      control = assert(scope._controls[request], 'active request is missing its control'),
    }
  end

  return entries
end

---@param scope vv-utils.async.Scope
---@return vv-utils.async.RequestHost
local function request_host(scope)
  return {
    snapshot = function(id, key)
      return scope._disposed, scope._epoch, scope._active[id], scope._lanes[key]
    end,
    detach = function(id, mode, lane, request)
      if scope._active[id] == request then scope._active[id] = nil end
      scope._controls[request] = nil
      if mode == 'latest' and lane.latest == request then lane.latest = nil end
    end,
    release_lane = function(key, lane)
      lane.references = lane.references - 1
      if lane.references == 0 and scope._lanes[key] == lane then scope._lanes[key] = nil end
    end,
  }
end

local function normalize_request_opts(opts)
  if opts == nil then opts = {} end
  assert(type(opts) == 'table', 'request options must be a table')

  local key = opts.key == nil and 'default' or opts.key
  local mode = opts.mode == nil and 'latest' or opts.mode

  assert(type(key) == 'string' or (type(key) == 'number' and key % 1 == 0),
    'request key must be a string or integer')
  assert(mode == 'latest' or mode == 'parallel', "request mode must be 'latest' or 'parallel'")
  assert(opts.cancel_previous == nil or type(opts.cancel_previous) == 'boolean',
    'cancel_previous must be a boolean')
  assert(opts.cancel == nil or type(opts.cancel) == 'function', 'cancel must be a function')
  assert(opts.dispose == nil or type(opts.dispose) == 'function', 'dispose must be a function')

  return key, mode
end

---开始一个由当前作用域持有的请求
---@param opts? vv-utils.async.RequestOpts
---@return vv-utils.async.Request
function Scope:begin(opts)
  assert(not self._disposed, 'cannot begin a request on a disposed scope')
  local key, mode = normalize_request_opts(opts)
  opts = opts or {}

  local lane = self._lanes[key]
  if lane then
    assert(lane.mode == mode,
      'request mode must match the existing lane mode for key ' .. tostring(key))
  else
    lane = { mode = mode, revision = 0, references = 0 }
    self._lanes[key] = lane
  end

  lane.references = lane.references + 1
  if mode == 'latest' then lane.revision = lane.revision + 1 end
  self._next_id = self._next_id + 1

  local request, control = Request.new(request_host(self), {
    id = self._next_id,
    epoch = self._epoch,
    key = key,
    revision = lane.revision,
    mode = mode,
    lane = lane,
  })

  self._active[self._next_id] = request
  self._controls[request] = control

  if mode == 'latest' then
    local previous = lane.latest
    lane.latest = request

    if previous and previous ~= request then
      local cancel_previous = opts.cancel_previous
      if cancel_previous == nil then cancel_previous = self._cancel_previous end
      local previous_control = self._controls[previous]
      if cancel_previous then
        previous_control.terminate('cancelled', 'superseded', true)
      else
        previous_control.invalidate('superseded')
      end
    end
  end

  if opts.cancel then request:set_cancel(opts.cancel) end
  if opts.dispose then request:set_disposer(opts.dispose) end
  return request
end

---只在逻辑上废弃所有在途请求，并保持作用域可复用
function Scope:invalidate()
  if self._disposed then return end

  self._epoch = self._epoch + 1
  for _, entry in ipairs(active_snapshot(self)) do
    entry.control.invalidate('owner-invalidated')
  end
end

---取消并释放所有在途请求，并保持作用域可复用
function Scope:cancel()
  if self._disposed then return end

  self._epoch = self._epoch + 1
  for _, entry in ipairs(active_snapshot(self)) do
    entry.control.terminate('cancelled', 'cancelled', true)
  end
end

---永久关闭作用域并取消所有在途请求
function Scope:dispose()
  if self._disposed then return end

  self._disposed = true
  self._epoch = self._epoch + 1

  for _, entry in ipairs(active_snapshot(self)) do
    entry.control.terminate('cancelled', 'owner-disposed', true)
  end
end

---返回当前作用域是否已经永久关闭
---@return boolean
function Scope:is_disposed()
  return self._disposed
end

---@param opts? vv-utils.async.ScopeOpts
---@return vv-utils.async.Scope
function M.new(opts)
  if opts == nil then opts = {} end
  assert(type(opts) == 'table', 'scope options must be a table')
  assert(opts.cancel_previous == nil or type(opts.cancel_previous) == 'boolean',
    'cancel_previous must be a boolean')

  return setmetatable({
    _epoch = 0,
    _next_id = 0,
    _disposed = false,
    _cancel_previous = opts.cancel_previous == true,
    _active = {},
    _controls = {},
    _lanes = {},
  }, Scope)
end

return M
