-- vv-utils.animate — 通用补间动画引擎
-- uv_timer 驱动，支持 easing / id 去重 / int 取整

local uv = vim.uv or vim.loop

---@class VVAnimateOpts
---@field id? string|number        唯一标识，同 id 新动画自动 stop 旧的
---@field int? boolean             是否对 value 取整 @default false
---@field easing? string|fun(t:number, b:number, c:number, d:number):number @default 'linear'
---@field duration? number|{step?:number, total?:number} 毫秒 @default 20

---@class VVAnimateCtx
---@field prev number
---@field done boolean

---@alias VVAnimateCb fun(value: number, ctx: VVAnimateCtx)

---@class VVAnimation
---@field id string|number
---@field timer uv.uv_timer_t|nil
---@field steps number[]|nil
---@field _step number|nil
local Animation = {}
Animation.__index = Animation

local M = {}

local _id = 0
---@type table<string|number, VVAnimation>
local active = setmetatable({}, { __mode = 'v' })

local fps = 120

local easing_fns = {
  linear = function(t, b, c, d)
    return c * t / d + b
  end,
  outQuad = function(t, b, c, d)
    t = t / d
    return -c * t * (t - 2) + b
  end,
  outCubic = function(t, b, c, d)
    t = t / d - 1
    return c * (t * t * t + 1) + b
  end,
  inQuad = function(t, b, c, d)
    t = t / d
    return c * t * t + b
  end,
  inOutQuad = function(t, b, c, d)
    t = t / d * 2
    if t < 1 then
      return c / 2 * t * t + b
    end
    t = t - 1
    return -c / 2 * (t * (t - 2) - 1) + b
  end,
}

---@param opts? VVAnimateOpts
---@return VVAnimation
function Animation.new(opts)
  opts = opts or {}
  _id = _id + 1
  local id = opts.id or _id

  if active[id] then
    active[id]:stop()
    active[id] = nil
  end

  local self = setmetatable({}, Animation)
  self.id = id
  self._opts = opts
  active[id] = self
  return self
end

---@param from number
---@param to number
---@param cb VVAnimateCb
function Animation:start(from, to, cb)
  self:stop()
  if from == to then
    cb(from, { prev = from, done = true })
    return self
  end

  local opts = self._opts
  local d = type(opts.duration) == 'table' and opts.duration or { step = opts.duration or 20 }
  ---@cast d {step?:number, total?:number}

  local duration = 0
  if d.step then
    duration = d.step * math.abs(to - from)
    duration = math.min(duration, d.total or duration)
  elseif d.total then
    duration = d.total
  end
  if duration <= 0 then duration = 250 end

  local step_duration = math.max(duration / math.abs(to - from), 1000 / fps)
  local step_count = math.max(math.floor(duration / step_duration + 0.5), 2)

  local easing = opts.easing or 'linear'
  local easing_fn = type(easing) == 'function' and easing or easing_fns[easing] or easing_fns.linear

  -- i 从 0 起、定义域 d = step_count - 1，使首帧 t=0 → from、末帧硬编码 to，
  -- 完整覆盖 [0, d]，消除原本 i=1 起步跳过 from 的首帧突变
  -- step_count >= 2（见上 math.max(..., 2)），故 d >= 1 不会除零
  self.steps = {}
  for i = 0, step_count - 1 do
    local value
    if i == step_count - 1 then
      value = to
    else
      value = easing_fn(i, from, to - from, step_count - 1)
    end
    if opts.int then
      value = math.floor(value + 0.5)
    end
    self.steps[#self.steps + 1] = value
  end

  self._step = 0
  active[self.id] = self
  self.timer = assert(uv.new_timer())
  self.timer:start(0, math.floor(step_duration), function()
    vim.schedule(function()
      self:_tick(cb)
    end)
  end)
  return self
end

---@param cb VVAnimateCb
function Animation:_tick(cb)
  if not self.steps or not self._step or self._step >= #self.steps then
    self:stop()
    return
  end
  self._step = self._step + 1
  local value = self.steps[self._step]
  local prev = self.steps[self._step - 1] or value
  local done = self._step >= #self.steps
  cb(value, { prev = prev, done = done })
end

function Animation:stop()
  if self.timer then
    if self.timer:is_active() then
      self.timer:stop()
    end
    if not self.timer:is_closing() then
      self.timer:close()
    end
    self.timer = nil
  end
  self.steps = nil
  self._step = nil
end

---@param from number
---@param to number
---@param cb VVAnimateCb
---@param opts? VVAnimateOpts
---@return VVAnimation
function M.add(from, to, cb, opts)
  return Animation.new(opts):start(from, to, cb)
end

---@param id string|number
function M.del(id)
  if active[id] then
    active[id]:stop()
    active[id] = nil
  end
end

M.easing = easing_fns

return M
