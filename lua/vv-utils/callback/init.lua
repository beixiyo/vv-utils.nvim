---回调调用次数与失效控制
local M = {}

---限制回调最多执行指定次数
---@param callback function
---@param max_calls? integer 最大执行次数 @default 1
---@return function invoke 保留 callback 的参数与返回值，达到上限后不再执行
---@return fun() disable 立即禁止后续执行，幂等
function M.limit(callback, max_calls)
  assert(type(callback) == 'function', 'callback must be a function')
  max_calls = max_calls == nil and 1 or max_calls
  assert(type(max_calls) == 'number' and max_calls % 1 == 0 and max_calls > 0,
    'max_calls must be a positive integer')

  local calls = 0
  local disabled = false

  local function invoke(...)
    if disabled or calls >= max_calls then return end
    calls = calls + 1
    return callback(...)
  end

  local function disable()
    disabled = true
  end

  return invoke, disable
end

return M
