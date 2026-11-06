-- 按时间预算分片执行的批处理器：批量重活不独占主线程
--
-- 固定「N 个/批」× 重 worker 的循环会一次阻塞主线程几百毫秒；本模块把批粒度换成
-- 时间预算：每处理一项检查一次片预算，超预算立即经 uv timer 让出到下一个事件循环，
-- 中间的按键、重绘与动画得以执行
--
-- 让出必须走 uv timer 而不是 vim.schedule 自递归：schedule 的队列在同一次事件循环
-- 批次里被排空，新排入的回调会被立刻接着执行，分片就退化成忙循环，主线程一样卡死
-- （fs.dir_scan 实测 89 万文件的目录会连续占用主线程 5.9s）
--
-- 边界：
--   • 每片至少推进一项：预算被配成 0 时，光看预算会让每片处理 0 项而永远调度下去
--   • 单项工作无法再切（Lua 无抢占）：超预算的单项会完整执行，结束后才让出
--   • worker 抛错或返回 err 字符串都记入 errors 并继续，不中断整批
--   • is_valid 在每项执行前检查；返回 false 立即停止排片，结果以 aborted=true 报告
--   • cancel 后不再调度下一片、不触发 on_done；已处理的项不回滚
--   • on_done 总在 vim.schedule 里触发（含空列表），调用方无需区分同步 / 异步起点

local uv = vim.uv or vim.loop

local M = {}

local DEFAULT_BUDGET_MS = 8
local DEFAULT_BUDGET_ITEMS = 20

---分片执行一批工作项
---@param opts vv-utils.async.BatchOpts
---@return vv-utils.async.BatchHandle
function M.run(opts)
  local items = opts.items or {}
  local worker = assert(opts.worker, 'worker is required')
  local on_done = opts.on_done
  local on_progress = opts.on_progress
  local is_valid = opts.is_valid
  local budget_ms = math.max(0, opts.budget_ms or DEFAULT_BUDGET_MS)
  local budget_items = math.max(1, opts.budget_items or DEFAULT_BUDGET_ITEMS)

  local total = #items
  local index = 1
  local done = 0
  local errors = {}
  local cancelled, finished = false, false
  local timer ---@type uv.uv_timer_t?

  local function stop_timer()
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    timer = nil
  end

  ---@param aborted boolean
  local function finish(aborted)
    if finished or cancelled then return end
    finished = true
    stop_timer()
    if on_done then
      on_done({
        done = done,
        total = total,
        aborted = aborted,
        errors = errors,
      })
    end
  end

  local step

  local function schedule_next()
    if cancelled or finished then return end
    timer = timer or uv.new_timer()
    if not timer then return finish(true) end
    timer:start(0, 0, vim.schedule_wrap(step))
  end

  step = function()
    if cancelled or finished then return end

    local slice_started = uv.hrtime()
    local processed = 0

    while index <= total and (processed == 0 or (
      processed < budget_items
      and (uv.hrtime() - slice_started) / 1e6 < budget_ms
    )) do
      if cancelled or finished then return end
      if is_valid and not is_valid() then return finish(true) end

      local item = items[index]
      local current = index
      index = index + 1
      processed = processed + 1
      done = done + 1

      local ok, err = pcall(worker, item, current)
      if not ok then
        errors[#errors + 1] = { item = item, index = current, err = tostring(err) }
      elseif type(err) == 'string' then
        errors[#errors + 1] = { item = item, index = current, err = err }
      end
    end

    if cancelled or finished then return end
    if on_progress then on_progress(done, total) end
    if cancelled or finished then return end

    if index > total then return finish(false) end
    schedule_next()
  end

  vim.schedule(function()
    if cancelled or finished then return end
    if is_valid and not is_valid() then return finish(true) end
    step()
  end)

  return {
    ---幂等：停止排片且不触发 on_done
    cancel = function()
      if finished or cancelled then return end
      cancelled = true
      stop_timer()
    end,
  }
end

return M
