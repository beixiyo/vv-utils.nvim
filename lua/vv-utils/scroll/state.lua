-- vv-utils.scroll.state — 滚动配置与跨模块运行状态

local uv = vim.uv or vim.loop

local M = {}

M.defaults = {
  enabled = true,
  auto = true,
  auto_min_lines = 4,
  auto_max_steps = 10,
  duration = 180,
  key_duration = 120,
  auto_duration = 108,
  easing = 'linear',
  step = 5,
  frame_ms = 12,
  mouse = 'native',
  mouse_step = 3,
}

M.runtime = {
  win_seq = {},
  win_timer = {},
  auto_state = {},
  auto_busy = {},
  manual_scroll_count = 0,
  manual_suppress_until = 0,
}

local config = vim.deepcopy(M.defaults)

---@param opts? vv-utils.scroll.Opts
function M.setup(opts)
  config = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})
end

---@return vv-utils.scroll.Opts
function M.get_config()
  return vim.deepcopy(config)
end

---@return vv-utils.scroll.Opts
function M.config()
  return config
end

---@param name string
---@return number
function M.duration_limit(name)
  local value = config[name]
  if type(value) == 'number' then
    return math.max(0, value)
  end

  return math.max(0, config.duration or M.defaults.duration)
end

---@return integer
function M.suppress_ms()
  return math.max(40, (config.frame_ms or M.defaults.frame_ms) * 3)
end

function M.begin_manual_scroll()
  M.runtime.manual_scroll_count = M.runtime.manual_scroll_count + 1
  M.runtime.manual_suppress_until = uv.now() + M.suppress_ms()
end

function M.touch_manual_scroll()
  M.runtime.manual_suppress_until = uv.now() + M.suppress_ms()
end

function M.end_manual_scroll()
  M.runtime.manual_scroll_count = math.max(0, M.runtime.manual_scroll_count - 1)
  M.touch_manual_scroll()
end

---@return boolean
function M.auto_suppressed()
  return M.runtime.manual_scroll_count > 0
    or uv.now() < M.runtime.manual_suppress_until
end

return M
