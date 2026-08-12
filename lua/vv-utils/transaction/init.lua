-- 通用事务 facade：创建实例并暴露稳定公共 API

require('vv-utils.transaction.types')

local Apply = require('vv-utils.transaction.apply')
local Operation = require('vv-utils.transaction.operation')
local Runtime = require('vv-utils.transaction.runtime')
local Undo = require('vv-utils.transaction.undo')

local M = {}
local Transaction = {}
Transaction.__index = Transaction

---@param opts? vv-utils.transaction.Options
---@return vv-utils.transaction.Transaction
function M.new(opts)
  opts = opts or {}
  assert(type(opts) == 'table', 'transaction.new: opts must be a table')
  return setmetatable({
    operations = Operation.normalize_list(opts.operations),
    busy = false,
    locked = false,
    inconsistent = false,
    last = nil,
  }, Transaction)
end

---@param operations? vv-utils.transaction.Operation[]
---@param context? any
---@param callback? fun(ok: boolean, error?: any, result?: vv-utils.transaction.Result)
---@return boolean? ok
---@return any? error
---@return vv-utils.transaction.Result? result
function Transaction:run(operations, context, callback)
  return Apply.run(self, operations, context, callback)
end

---@param operations? vv-utils.transaction.Operation[]
---@param context? any
---@param callback? fun(ok: boolean, error?: any, result?: vv-utils.transaction.Result)
function Transaction:apply(operations, context, callback)
  return self:run(operations, context, callback)
end

---@param context? any
---@param callback? fun(ok: boolean, error?: any, result?: vv-utils.transaction.Result)
function Transaction:undo(context, callback)
  return Undo.run(self, context, callback)
end

---@return boolean
function Transaction:can_undo()
  return self.last ~= nil and self.last.undoable == true and not self.locked and not self.inconsistent
end

---@return boolean
function Transaction:is_busy()
  return self.busy
end

---@return boolean
function Transaction:is_locked()
  return self.locked or self.inconsistent
end

---@param error any
---@param touched? boolean @default true
---@return vv-utils.transaction.Failure
function M.failure(error, touched)
  return Operation.failure(error, touched)
end

M.ASYNC = Operation.ASYNC
M.BUSY_ERROR = Runtime.BUSY_ERROR
M.LOCKED_ERROR = Runtime.LOCKED_ERROR
M.Transaction = Transaction

return M
