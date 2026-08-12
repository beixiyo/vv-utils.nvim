-- 通用事务撤回流程：逆序补偿，失败时恢复事务后状态

local Operation = require('vv-utils.transaction.operation')
local Runtime = require('vv-utils.transaction.runtime')
local unpack_values = unpack or table.unpack

local M = {}

function M.run(transaction, context, callback)
  if type(context) == 'function' then callback, context = context, nil end
  if transaction.busy then return Runtime.reject(callback, Runtime.BUSY_ERROR) end
  if transaction.locked or transaction.inconsistent then
    return Runtime.reject(callback, Runtime.LOCKED_ERROR)
  end
  if not transaction.last or not transaction.last.undoable then
    return Runtime.reject(callback, 'nothing to undo')
  end
  transaction.busy = true

  local completed = false
  local return_values
  local function finish(ok, error, result)
    if completed then return end
    completed = true
    return_values = { ok, error, result }
    transaction.busy = false
    Runtime.safe_callback(callback, ok, error, result)
  end

  local record = transaction.last
  local states = record.operations
  local undo_context = context ~= nil and context or record.context
  local validation_index = 1
  local compensation_index = #states
  local attempted = {}
  local values = {}
  local compensate_next

  local function recover_after_failure(undo_error)
    local failures = {}
    local index = #attempted

    local function recover_next()
      if index == 0 then
        if #failures > 0 then
          transaction.locked = true
          transaction.inconsistent = true
        end
        finish(false, tostring(undo_error) .. Runtime.format_failures(failures), {
          phase = 'undo', touched = #attempted, count = #states,
          undoable = true, values = record.values or values,
        })
        return
      end
      local state = attempted[index]
      index = index - 1
      Operation.invoke(state.operation, 'apply', 'undo-recover', undo_context, state.result, function(ok, error)
        if not ok then Runtime.append_failure(failures, state, error) end
        recover_next()
      end)
    end

    recover_next()
  end

  compensate_next = function()
    if compensation_index == 0 then
      transaction.last = nil
      finish(true, nil, {
        phase = 'undo', touched = #attempted, count = #states,
        undoable = true, values = record.values or values,
      })
      return
    end

    local state = states[compensation_index]
    compensation_index = compensation_index - 1
    attempted[#attempted + 1] = state
    Operation.invoke(state.operation, 'compensate', 'undo', undo_context, state.result, function(ok, error, touched)
      if not ok then
        if touched == false then attempted[#attempted] = nil end
        recover_after_failure(error)
        return
      end
      compensate_next()
    end)
  end

  local function validate_next()
    if validation_index > #states then compensate_next() return end
    local state = states[validation_index]
    validation_index = validation_index + 1
    Operation.invoke(state.operation, 'validate', 'undo', undo_context, state.result, function(ok, error)
      if not ok then
        finish(false, tostring(error), {
          phase = 'undo', touched = 0, count = #states,
          undoable = true, values = record.values or values,
        })
        return
      end
      validate_next()
    end)
  end

  validate_next()
  if completed then return unpack_values(return_values) end
  return nil
end

return M
