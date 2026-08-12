-- 通用事务 operation 契约：归一化并统一同步返回与异步 callback

local M = {}
M.ASYNC = {}

local function unwrap_failure(value)
  if type(value) == 'table' and value.__transaction_failure == true then
    return value.error, value.touched ~= false
  end
  return value, true
end

local function callback_result(operation, first, second)
  if operation.callback_style == 'node' then
    if first == nil then return true, second, false end
    local error, touched = unwrap_failure(first)
    return false, error, touched
  end

  if first == false then
    local error, touched = unwrap_failure(second or 'operation failed')
    return false, error, touched
  end
  if first == nil and second ~= nil then
    local error, touched = unwrap_failure(second)
    return false, error, touched
  end
  if first == true or first == nil then return true, second, false end
  if type(first) == 'string' then return false, first, true end
  return true, first, false
end

local function return_result(first, second)
  if first == false then
    local error, touched = unwrap_failure(second or 'operation failed')
    return false, error, touched
  end
  if first == nil and second ~= nil then
    local error, touched = unwrap_failure(second)
    return false, error, touched
  end
  return true, first, false
end

function M.normalize(operation, index)
  if type(operation) == 'function' then operation = { apply = operation } end
  assert(type(operation) == 'table', 'transaction operation must be a table or function')

  local normalized = {}
  for key, value in pairs(operation) do normalized[key] = value end
  for _, field in ipairs({ 'validate', 'apply', 'rollback', 'compensate' }) do
    if normalized[field] ~= nil then
      assert(type(normalized[field]) == 'function',
        string.format('transaction operation %s must be a function', field))
    end
  end
  assert(normalized.async == nil or type(normalized.async) == 'boolean',
    'transaction operation async must be a boolean')
  assert(normalized.callback == nil or type(normalized.callback) == 'boolean',
    'transaction operation callback must be a boolean')
  assert(normalized.callback_style == nil
    or normalized.callback_style == 'boolean'
    or normalized.callback_style == 'node',
    'transaction operation callback_style must be boolean or node')

  normalized.name = normalized.name or ('operation #' .. tostring(index))
  normalized.compensate = normalized.compensate or normalized.rollback
  return normalized
end

function M.normalize_list(operations)
  if operations == nil then return {} end
  if type(operations) == 'function' then operations = { operations } end
  assert(type(operations) == 'table', 'transaction operations must be a list')

  local normalized = {}
  for index, operation in ipairs(operations) do
    normalized[index] = M.normalize(operation, index)
  end
  return normalized
end

function M.looks_like_list(value)
  if type(value) ~= 'table' then return false end
  if #value == 0 then return true end
  local first = value[1]
  if type(first) == 'function' then return true end
  if type(first) ~= 'table' then return false end
  return first.apply ~= nil or first.validate ~= nil
    or first.rollback ~= nil or first.compensate ~= nil
end

function M.invoke(operation, method, phase, context, result, on_complete)
  local fn = operation[method]
  if not fn then
    on_complete(method == 'validate', method == 'validate' and nil or 'operation has no ' .. method)
    return true
  end

  local completed = false
  local function complete_result(ok, value_or_error, touched)
    if completed then return end
    completed = true
    on_complete(ok, value_or_error, touched)
  end
  local function complete(first, second)
    complete_result(callback_result(operation, first, second))
  end

  local ok, first, second = pcall(fn, context, complete, result, phase)
  if completed then return true end
  if not ok then
    complete(false, first)
    return true
  end
  if operation.async == true or operation.callback == true or first == M.ASYNC then return false end
  if method == 'validate' and type(first) == 'string' then
    complete(false, first)
    return true
  end
  complete_result(return_result(first, second))
  return true
end

function M.failure(error, touched)
  return { __transaction_failure = true, error = error, touched = touched ~= false }
end

return M
