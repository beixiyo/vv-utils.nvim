---@class vv-utils.timer
local M = {}

--- 函数防抖：在 wait 毫秒内多次调用，仅最后一次生效
---
--- 内部创建一个常驻 uv timer。**不再使用时务必调用第二个返回值 `cancel`**，
--- 否则该 timer 句柄（fd / 内核定时器）会一直泄漏（libuv handle 必须显式 close 才释放）。
--- 旧调用方写 `local f = debounce(fn, ms)` 忽略 `cancel`，行为完全不变（向后兼容）。
---@param fn fun(...)
---@param wait integer|fun():integer 毫秒，或返回毫秒的函数
---@return fun(...) wrapped  防抖后的函数
---@return fun() cancel  停止并关闭内部 timer，幂等（可重复调用 / 已 close 安全）
function M.debounce(fn, wait)
  local timer = vim.uv.new_timer()

  local wrapped = function(...)
    if not timer or timer:is_closing() then return end
    local args = { ... }
    timer:stop()

    local ms = type(wait) == 'function' and wait() or wait
    if ms == 0 then ms = 1 end
    timer:start(ms, 0, vim.schedule_wrap(function()
      fn(unpack(args))
    end))
  end

  local cancel = function()
    if not timer or timer:is_closing() then return end
    timer:stop()
    timer:close()
  end

  return wrapped, cancel
end

--- 函数节流：每 limit 毫秒内最多执行一次
---
--- 内部创建一个常驻 uv timer。**不再使用时务必调用第二个返回值 `cancel`**，
--- 否则该 timer 句柄会一直泄漏（与 `debounce` 同）。旧调用方写 `local f = throttle(fn, ms)`
--- 忽略 `cancel`，行为不变（向后兼容）。
---@param fn fun(...)
---@param limit integer|fun():integer 毫秒，或返回毫秒的函数
---@return fun(...) wrapped  节流后的函数
---@return fun() cancel  停止并关闭内部 timer，幂等（可重复调用 / 已 close 安全）
function M.throttle(fn, limit)
  local timer = vim.uv.new_timer()
  local running = false

  local wrapped = function(...)
    if not timer or timer:is_closing() then return end
    if running then return end
    local args = { ... }

    running = true

    -- 先安排复位再调 fn：即使 fn 抛错（向上传播，与原行为一致），running 也已被安排在
    -- limit 毫秒后复位，不会永久卡 true 导致节流彻底失效。
    local ms = type(limit) == 'function' and limit() or limit
    if ms == 0 then
      running = false
    else
      timer:start(ms, 0, function()
        running = false
      end)
    end

    fn(unpack(args))
  end

  local cancel = function()
    if not timer or timer:is_closing() then return end
    timer:stop()
    timer:close()
  end

  return wrapped, cancel
end

return M
