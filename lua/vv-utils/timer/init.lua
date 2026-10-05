---@class vv-utils.timer
local M = {}

--- 函数防抖：在 wait 毫秒内多次调用，仅最后一次生效
---
--- 内部创建一个常驻 uv timer。**不再使用时务必调用第二个返回值 `cancel`**，
--- 否则该 timer 句柄（fd / 内核定时器）会一直泄漏（libuv handle 必须显式 close 才释放）
--- 旧调用方写 `local f = debounce(fn, ms)` 忽略 `cancel`，行为完全不变（向后兼容）
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
--- 前沿立即执行；窗口内的后续调用默认丢弃。`opts.trailing = true` 时，窗口内的调用合并为一次，
--- 在窗口结束时用**最后一次**的参数补执行（并开启新窗口）。异步结果只请求一次刷新的场景
--- （如 Git diff 完成后重绘）必须开 trailing，否则落在窗口内的那次刷新会被永久丢掉
---
--- 内部创建一个常驻 uv timer。**不再使用时务必调用第二个返回值 `cancel`**，
--- 否则该 timer 句柄会一直泄漏（与 `debounce` 同）。cancel 同时丢弃尚未补执行的尾随调用
---@param fn fun(...)
---@param limit integer|fun():integer 毫秒，或返回毫秒的函数
---@param opts? VVTimerThrottleOpts
---@return fun(...) wrapped  节流后的函数
---@return fun() cancel  停止并关闭内部 timer，幂等（可重复调用 / 已 close 安全）
function M.throttle(fn, limit, opts)
  local trailing = opts ~= nil and opts.trailing == true
  local timer = vim.uv.new_timer()
  local running = false
  local pending = nil ---@type { n: integer }?

  local wrapped

  -- trailing 的补执行要调 fn，必须回到主线程；非 trailing 只复位标志，可直接在 fast event 里做
  local on_window_end = trailing and vim.schedule_wrap(function()
    running = false
    if not pending or not timer or timer:is_closing() then return end

    local args = pending
    pending = nil
    wrapped(unpack(args, 1, args.n))
  end) or function()
    running = false
  end

  wrapped = function(...)
    if not timer or timer:is_closing() then return end
    if running then
      if trailing then pending = { n = select('#', ...), ... } end
      return
    end
    local args = { n = select('#', ...), ... }

    running = true

    -- 先安排复位再调 fn：即使 fn 抛错（向上传播，与原行为一致），running 也已被安排在
    -- limit 毫秒后复位，不会永久卡 true 导致节流彻底失效
    local ms = type(limit) == 'function' and limit() or limit
    if ms == 0 then
      running = false
    else
      timer:start(ms, 0, on_window_end)
    end

    fn(unpack(args, 1, args.n))
  end

  local cancel = function()
    pending = nil
    if not timer or timer:is_closing() then return end
    timer:stop()
    timer:close()
  end

  return wrapped, cancel
end

return M

---@class VVTimerThrottleOpts
---@field trailing? boolean 窗口内被丢弃的调用是否在窗口结束时用最后一次参数补执行一次 @default false
