---@class vv-utils.timer
local M = {}

--- 函数防抖：在 wait 毫秒内多次调用，仅最后一次生效
---@param fn fun(...)
---@param wait integer|fun():integer 毫秒，或返回毫秒的函数
---@return fun(...)
function M.debounce(fn, wait)
  local timer = vim.uv.new_timer()

  return function(...)
    local args = { ... }
    timer:stop()

    local ms = type(wait) == 'function' and wait() or wait
    if ms == 0 then
      vim.schedule(function() fn(unpack(args)) end)
    else
      timer:start(ms, 0, vim.schedule_wrap(function()
        fn(unpack(args))
      end))
    end
  end
end

--- 函数节流：每 limit 毫秒内最多执行一次
---@param fn fun(...)
---@param limit integer|fun():integer 毫秒，或返回毫秒的函数
---@return fun(...)
function M.throttle(fn, limit)
  local timer = vim.uv.new_timer()
  local running = false

  return function(...)
    if running then return end
    local args = { ... }

    running = true
    fn(unpack(args))

    local ms = type(limit) == 'function' and limit() or limit
    if ms == 0 then
      running = false
    else
      timer:start(ms, 0, function()
        running = false
      end)
    end
  end
end

return M
