-- 通用事务应用流程：完整预检、顺序应用和失败逆序补偿

local Operation = require('vv-utils.transaction.operation')
local Runtime = require('vv-utils.transaction.runtime')
local unpack_values = unpack or table.unpack

local M = {}

function M.run(transaction, operations, context, callback)
  if type(operations) == 'function' then
    callback, operations, context = operations, nil, nil
  elseif operations == nil then
    if type(context) == 'function' then callback, context = context, nil end
  elseif not Operation.looks_like_list(operations)
    or (#operations == 0 and #transaction.operations > 0)
  then
    callback = type(context) == 'function' and context or callback
    context, operations = operations, nil
  elseif type(context) == 'function' then
    callback, context = context, nil
  end

  if transaction.busy then return Runtime.reject(callback, Runtime.BUSY_ERROR) end
  if transaction.locked or transaction.inconsistent then
    return Runtime.reject(callback, Runtime.LOCKED_ERROR)
  end

  local normalized = Operation.normalize_list(operations or transaction.operations)
  if #normalized == 0 then return Runtime.reject(callback, 'no operations') end
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

  local attempted = {}
  local values = {}
  local validation_index = 1
  local apply_index = 1
  local apply_next

  local function compensate_failed(apply_error)
    local failures = {}
    local index = #attempted

    local function compensate_next()
      if index == 0 then
        if #failures > 0 then
          transaction.locked = true
          transaction.inconsistent = true
        end
        finish(false, tostring(apply_error) .. Runtime.format_failures(failures), {
          phase = 'apply', touched = #attempted, count = #normalized,
          undoable = false, values = values,
        })
        return
      end

      local state = attempted[index]
      index = index - 1
      if not state.operation.compensate then
        Runtime.append_failure(failures, state, 'operation has no compensation')
        compensate_next()
        return
      end
      Operation.invoke(state.operation, 'compensate', 'apply', context, state.result, function(ok, error)
        if not ok then Runtime.append_failure(failures, state, error) end
        compensate_next()
      end)
    end

    compensate_next()
  end

  apply_next = function()
    if apply_index > #normalized then
      local undoable = true
      for _, operation in ipairs(normalized) do
        if not operation.compensate then undoable = false break end
      end
      transaction.last = {
        operations = Runtime.copy_states(attempted), context = context,
        undoable = undoable, values = values,
      }
      finish(true, nil, {
        phase = 'apply', touched = #attempted, count = #normalized,
        undoable = undoable, values = values,
      })
      return
    end

    local state = { operation = normalized[apply_index], result = nil }
    attempted[#attempted + 1] = state
    local index = apply_index
    apply_index = apply_index + 1
    Operation.invoke(state.operation, 'apply', 'apply', context, nil, function(ok, result, touched)
      if not ok then
        if touched == false then attempted[#attempted] = nil end
        compensate_failed(result)
        return
      end
      state.result = result
      values[index] = result
      apply_next()
    end)
  end

  local function validate_next()
    if validation_index > #normalized then apply_next() return end
    local operation = normalized[validation_index]
    validation_index = validation_index + 1
    Operation.invoke(operation, 'validate', 'apply', context, nil, function(ok, error)
      if not ok then
        finish(false, tostring(error), {
          phase = 'apply', touched = 0, count = #normalized,
          undoable = false, values = values,
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
