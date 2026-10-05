-- vv-utils.loading.clock — 所有 loading 实例共享的帧时钟
--
-- 按 interval_ms 分组：同一间隔只开一个 uv timer，订阅者在同一 tick 收到同一帧序号，
-- 因此多个 spinner 的帧完全同步。分组最后一个订阅者退订时立即 stop + close timer

local M = {}

---@type table<integer, vv-utils.loading.ClockGroup>
local groups = {}

---@param interval_ms integer
---@return vv-utils.loading.ClockGroup
local function ensure_group(interval_ms)
  local group = groups[interval_ms]
  if group then return group end

  group = { timer = assert(vim.uv.new_timer()), tick = 0, subs = {}, count = 0 }
  groups[interval_ms] = group
  group.timer:start(interval_ms, interval_ms, vim.schedule_wrap(function()
    if groups[interval_ms] ~= group then return end
    group.tick = group.tick + 1

    -- 回调里可能退订（stop），先拍快照再遍历
    local snapshot = {}
    for key, fn in pairs(group.subs) do snapshot[#snapshot + 1] = { key, fn } end
    for _, item in ipairs(snapshot) do
      if group.subs[item[1]] then item[2](group.tick) end
    end
  end))
  return group
end

--- 订阅帧时钟。订阅时立即同步回调一次当前 tick，之后每 interval_ms 回调一次
---@param interval_ms integer
---@param fn fun(tick: integer)
---@return fun() unsubscribe 幂等
function M.subscribe(interval_ms, fn)
  local group = ensure_group(interval_ms)
  local key = {}
  group.subs[key] = fn
  group.count = group.count + 1

  fn(group.tick)

  return function()
    if not group.subs[key] then return end
    group.subs[key] = nil
    group.count = group.count - 1
    if group.count > 0 then return end

    group.timer:stop()
    if not group.timer:is_closing() then group.timer:close() end
    if groups[interval_ms] == group then groups[interval_ms] = nil end
  end
end

--- 当前活跃的 timer 数（测试用：验证共享与释放）
---@return integer
function M._timer_count()
  local n = 0
  for _ in pairs(groups) do n = n + 1 end
  return n
end

return M

---@class vv-utils.loading.ClockGroup
---@field timer uv.uv_timer_t
---@field tick integer
---@field subs table<table, fun(tick: integer)>
---@field count integer
