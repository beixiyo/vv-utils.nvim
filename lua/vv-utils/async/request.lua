-- 由 vv-utils.async.Scope 持有的请求句柄
-- Request 实例只暴露公共 API；内部状态由每实例 metatable 闭包持有

---@class vv-utils.async.RequestHost
---@field snapshot fun(id: integer, key: vv-utils.async.RequestKey): boolean, integer, vv-utils.async.Request?, vv-utils.async.Lane?
---@field detach fun(id: integer, mode: vv-utils.async.RequestMode, lane: vv-utils.async.Lane, request: vv-utils.async.Request)
---@field release_lane fun(key: vv-utils.async.RequestKey, lane: vv-utils.async.Lane)

---@class vv-utils.async.RequestControl
---@field invalidate fun(reason: vv-utils.async.RequestReason): boolean
---@field terminate fun(state: 'finished'|'cancelled'|'disposed', reason: vv-utils.async.RequestReason, cancel: boolean): boolean

---@class vv-utils.async.Request
---@field is_current fun(self: vv-utils.async.Request): boolean
---@field invalidate fun(self: vv-utils.async.Request): boolean
---@field set_cancel fun(self: vv-utils.async.Request, cancel: fun()): vv-utils.async.Request
---@field set_disposer fun(self: vv-utils.async.Request, disposer: fun()): vv-utils.async.Request
---@field finish fun(self: vv-utils.async.Request): boolean
---@field cancel fun(self: vv-utils.async.Request): boolean
---@field dispose fun(self: vv-utils.async.Request): boolean
---@field reason fun(self: vv-utils.async.Request): vv-utils.async.RequestReason?

---@class vv-utils.async.RequestState
---@field host vv-utils.async.RequestHost
---@field id integer
---@field epoch integer
---@field key vv-utils.async.RequestKey
---@field revision integer
---@field mode vv-utils.async.RequestMode
---@field lane vv-utils.async.Lane
---@field lane_released boolean
---@field state 'active'|'invalidated'|'finished'|'cancelled'|'disposed'
---@field reason? vv-utils.async.RequestReason
---@field cancel { callback?: fun(), requested: boolean, called: boolean }
---@field disposer { callback?: fun(), requested: boolean, called: boolean }

local M = {}

local function report_cleanup_error(kind, err)
  pcall(function()
    local ok, message = pcall(tostring, err)
    if not ok then message = '<error object could not be formatted>' end
    vim.notify(('vv-utils.async %s failed: %s'):format(kind, message), vim.log.levels.ERROR)
  end)
end

---@param slot { callback?: fun(), requested: boolean, called: boolean }
---@param kind 'cancel'|'disposer'
local function invoke(slot, kind)
  if slot.called then return end

  local callback = slot.callback
  if not callback then return end

  slot.called = true
  local ok, err = pcall(callback)
  if not ok then report_cleanup_error(kind, err) end
end

---@param state vv-utils.async.RequestState
---@param request vv-utils.async.Request
---@return boolean
local function is_current(state, request)
  if state.state ~= 'active' then return false end

  local disposed, epoch, active, lane = state.host.snapshot(state.id, state.key)
  if disposed or state.epoch ~= epoch then return false end
  if active ~= request then return false end
  if lane ~= state.lane then return false end
  if state.mode == 'latest' and state.lane.latest ~= request then return false end

  return true
end

---@param state vv-utils.async.RequestState
---@return boolean
local function still_authorized(state)
  local disposed, epoch, _, lane = state.host.snapshot(state.id, state.key)
  if disposed or epoch ~= state.epoch then return false end
  if lane ~= state.lane then return false end
  if state.mode == 'latest' and state.lane.revision ~= state.revision then return false end
  return true
end

---@param state vv-utils.async.RequestState
---@param request vv-utils.async.Request
---@param reason vv-utils.async.RequestReason
---@return boolean changed
local function invalidate(state, request, reason)
  if state.state ~= 'active' then return false end

  state.state = 'invalidated'
  state.reason = reason

  if state.mode == 'latest' and state.lane.latest == request then
    state.lane.latest = nil
  end

  return true
end

---@param state vv-utils.async.RequestState
---@param request vv-utils.async.Request
---@param terminal_state 'finished'|'cancelled'|'disposed'
---@param reason vv-utils.async.RequestReason
---@param cancel boolean
---@return boolean remained_current
local function terminate(state, request, terminal_state, reason, cancel)
  if state.state == 'finished'
      or state.state == 'cancelled'
      or state.state == 'disposed' then
    return false
  end

  local was_current = is_current(state, request)
  local previous_reason = state.reason

  state.state = terminal_state
  state.reason = previous_reason or reason
  state.cancel.requested = cancel
  state.disposer.requested = true
  state.host.detach(state.id, state.mode, state.lane, request)

  if cancel then invoke(state.cancel, 'cancel') end

  invoke(state.disposer, 'disposer')
  local authorized = was_current and still_authorized(state)

  if not state.lane_released then
    state.lane_released = true
    state.host.release_lane(state.key, state.lane)
  end

  return authorized
end

---@param state vv-utils.async.RequestState
---@param request vv-utils.async.Request
---@return table
local function public_methods(state, request)
  return {
    ---@return boolean
    is_current = function() return is_current(state, request) end,
    ---@return boolean changed
    invalidate = function() return invalidate(state, request, 'invalidated') end,
    ---@param cancel fun()
    ---@return vv-utils.async.Request
    set_cancel = function(_, cancel)
      assert(type(cancel) == 'function', 'cancel must be a function')
      assert(not state.cancel.callback or state.cancel.callback == cancel, 'cancel callback is already set')
      state.cancel.callback = cancel
      if state.cancel.requested then invoke(state.cancel, 'cancel') end
      return request
    end,
    ---@param disposer fun()
    ---@return vv-utils.async.Request
    set_disposer = function(_, disposer)
      assert(type(disposer) == 'function', 'disposer must be a function')
      assert(not state.disposer.callback or state.disposer.callback == disposer, 'disposer is already set')
      state.disposer.callback = disposer
      if state.disposer.requested then invoke(state.disposer, 'disposer') end
      return request
    end,
    ---@return boolean may_publish
    finish = function() return terminate(state, request, 'finished', 'finished', false) end,
    ---@return boolean remained_current
    cancel = function() return terminate(state, request, 'cancelled', 'cancelled', true) end,
    ---@return boolean remained_current
    dispose = function() return terminate(state, request, 'disposed', 'disposed', false) end,
    ---@return vv-utils.async.RequestReason?
    reason = function() return state.reason end,
  }
end

---@param host vv-utils.async.RequestHost
---@param fields { id: integer, epoch: integer, key: vv-utils.async.RequestKey, revision: integer, mode: vv-utils.async.RequestMode, lane: vv-utils.async.Lane }
---@return vv-utils.async.Request request
---@return vv-utils.async.RequestControl control
function M.new(host, fields)
  local request = {}
  local state = {
    host = host,
    id = fields.id,
    epoch = fields.epoch,
    key = fields.key,
    revision = fields.revision,
    mode = fields.mode,
    lane = fields.lane,
    lane_released = false,
    state = 'active',
    cancel = { requested = false, called = false },
    disposer = { requested = false, called = false },
  }

  setmetatable(request, {
    __index = public_methods(state, request),
    __metatable = false,
  })

  return request, {
    invalidate = function(reason) return invalidate(state, request, reason) end,
    terminate = function(terminal_state, reason, cancel)
      return terminate(state, request, terminal_state, reason, cancel)
    end,
  }
end

return M
