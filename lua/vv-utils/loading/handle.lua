-- vv-utils.loading.handle — 所有 loading 形态共用的生命周期内核
--
-- 负责：延迟显示、订阅共享时钟、帧选择、文案更新、幂等停止
-- 具体画在哪里（extmark / 窗口 title / 回调）由 render / clear 两个策略函数决定：
--   render(frame, label) 返回 false 表示宿主资源已失效，handle 随即自行停止
--   clear() 只在曾经画过时于清理阶段调用一次
-- stop 可在 fast event（如 uv timer 回调）中调用：同步置停止、释放 uv 资源，
-- clear 与 on_stop 回调（会调用 vim API）经 vim.schedule 延后到主循环执行，只执行一次

local Clock = require('vv-utils.loading.clock')

local M = {}

-- 字段定义见文件底部（LuaLS 需要这一行把方法表绑定到类上）
---@class vv-utils.loading.Handle
local Handle = {}
Handle.__index = Handle

---@param spec vv-utils.loading.HandleSpec
---@return vv-utils.loading.Handle
function M.new(spec)
  local self = setmetatable({
    _spec = spec,
    _label = spec.label,
    _frame = spec.frames[1],
    _active = true,
    _visible = false,
    _on_stop = {},
  }, Handle)

  if spec.delay_ms > 0 then
    local timer = assert(vim.uv.new_timer())
    self._delay_timer = timer
    timer:start(spec.delay_ms, 0, vim.schedule_wrap(function()
      self:_close_delay_timer()
      if self._active then self:_show() end
    end))
  else
    self:_show()
  end

  return self
end

---@private
function Handle:_close_delay_timer()
  local timer = self._delay_timer
  if not timer then return end
  self._delay_timer = nil
  timer:stop()
  if not timer:is_closing() then timer:close() end
end

---@private
function Handle:_draw()
  if not self._active then return end
  if vim.in_fast_event() then
    if self._pending_draw then return end
    local pending = {}
    self._pending_draw = pending
    vim.schedule(function()
      if self._pending_draw ~= pending then return end
      self._pending_draw = nil
      self:_draw()
    end)
    return
  end

  -- 主循环已经重画则消费先前排队的更新，避免重复触发 render / on_frame
  self._pending_draw = nil
  local ok, result = pcall(self._spec.render, self._frame, self._label)
  if not ok then
    self:stop()
    vim.notify('vv-utils.loading: render failed: ' .. tostring(result), vim.log.levels.ERROR)
    return
  end
  if result == false then self:stop() end
end

---@private
function Handle:_show()
  self._visible = true
  if self._spec.static then
    self:_draw()
    return
  end

  local frames = self._spec.frames
  local unsubscribe = Clock.subscribe(self._spec.interval_ms, function(tick)
    self._frame = frames[tick % #frames + 1]
    self:_draw()
  end)
  -- subscribe 同步触发首帧；首帧里就已停止（render 返回 false）时 stop 拿不到退订函数，这里补退
  if self._active then
    self._unsubscribe = unsubscribe
  else
    unsubscribe()
  end
end

--- 更新帧后附带的文案并重画（未显示时只记录；fast event 中合并延后到主循环）
---@param label string?
function Handle:set_label(label)
  if not self._active then return end
  self._label = label
  if self._visible then self:_draw() end
end

--- 按当前帧重画（未显示或已停止时无操作；fast event 中合并延后到主循环）
function Handle:redraw()
  if self._visible then self:_draw() end
end

---@return boolean
function Handle:is_active()
  return self._active
end

--- 以 ERROR 级 vim.notify 逐条报告错误（调用方保证在主循环中）
---@param errors string[]
local function report_errors(errors)
  for _, err in ipairs(errors) do
    vim.notify('vv-utils.loading: ' .. err, vim.log.levels.ERROR)
  end
end

--- 在主循环中执行 fn：当前处于 fast event 时经 vim.schedule 延后，否则立即执行
---@param fn fun()
local function on_main_loop(fn)
  if vim.in_fast_event() then
    vim.schedule(fn)
  else
    fn()
  end
end

--- 停止后执行的清理（如删除 autocmd）
--- 已停止且清理已完成时立即执行（fast event 中延后到主循环）；停止后清理尚未执行（fast event 中 stop、
--- 主循环未轮到）时排进同一批，在 clear 之后执行。抛错时以 ERROR 级 vim.notify 报告，不抛给调用方
---@param fn fun()
function Handle:on_stop(fn)
  if not self._finalized then
    self._on_stop[#self._on_stop + 1] = fn
    return
  end
  on_main_loop(function()
    local ok, err = pcall(fn)
    if not ok then report_errors({ 'on_stop failed: ' .. tostring(err) }) end
  end)
end

--- 主循环中执行一次的清理：clear（曾经画过时）→ 全部 on_stop
--- clear / on_stop 抛错各自收集，不中断后续步骤，全部执行完才以 ERROR 级 vim.notify 报告
---@private
function Handle:_finalize()
  if self._finalized then return end
  self._finalized = true

  local errors = {}
  if self._visible and self._spec.clear then
    local ok, err = pcall(self._spec.clear)
    if not ok then errors[#errors + 1] = 'clear failed: ' .. tostring(err) end
  end

  local on_stop = self._on_stop
  self._on_stop = {}
  for _, fn in ipairs(on_stop) do
    local ok, err = pcall(fn)
    if not ok then errors[#errors + 1] = 'on_stop failed: ' .. tostring(err) end
  end
  report_errors(errors)
end

--- 停止动画并清掉已画内容，幂等
--- 同步：置为停止、释放延迟 timer 与时钟订阅（纯 uv 操作，fast event 中同样安全）
--- clear 与 on_stop 回调：主循环中调用时同步执行；fast event 中调用时经 vim.schedule 延后到主循环
--- 已在 fast event 中停止、延后清理尚未执行时，主循环再调 stop() 会就地完成清理，之后排队的延后清理直接返回
--- 无论在哪调用、调用几次，clear 与每个 on_stop 都只执行一次
--- clear / on_stop 抛错时以 ERROR 级 vim.notify 报告（与渲染失败一致，前缀 vv-utils.loading: clear failed /
--- on_stop failed），不中断后续回调；报告在全部清理完成后才发出
function Handle:stop()
  if not self._active then
    -- 保证「主循环中调用 stop() 返回时已清理完」：_finalize 幂等，排队中的延后清理随后直接返回
    if not self._finalized and not vim.in_fast_event() then self:_finalize() end
    return
  end
  self._active = false
  self._pending_draw = nil
  self:_close_delay_timer()
  if self._unsubscribe then
    self._unsubscribe()
    self._unsubscribe = nil
  end
  on_main_loop(function() self:_finalize() end)
end

return M

---@class vv-utils.loading.HandleSpec
---@field frames string[]
---@field interval_ms integer
---@field delay_ms integer
---@field label? string
---@field static? boolean 只画首帧，不订阅时钟（同步阻塞场景）
---@field render fun(frame: string, label: string?): boolean?
---@field clear? fun()

---@class vv-utils.loading.Handle
---@field private _spec vv-utils.loading.HandleSpec
---@field private _label string?
---@field private _frame string
---@field private _active boolean
---@field private _visible boolean
---@field private _delay_timer uv.uv_timer_t?
---@field private _unsubscribe fun()?
---@field private _on_stop fun()[]
---@field private _finalized? boolean clear / on_stop 已在主循环执行完
---@field private _pending_draw? table 合并排队的 fast-event 重画身份
