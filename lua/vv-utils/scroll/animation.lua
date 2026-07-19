-- vv-utils.scroll.animation — 手动滚动与自动视口跳转动画

local animate = require('vv-utils.animate')
local state = require('vv-utils.scroll.state')
local viewport = require('vv-utils.scroll.viewport')

local uv = vim.uv or vim.loop
local M = {}

local function close_timer(timer)
  if not timer then return end
  if timer:is_active() then
    timer:stop()
  end
  if not timer:is_closing() then
    timer:close()
  end
end

local function stop_scroll(win_id, seq)
  local runtime = state.runtime
  local active = runtime.win_timer[win_id]
  if not active then return end
  if seq and active.seq ~= seq then return end

  close_timer(active.timer)
  if runtime.win_timer[win_id] == active then
    runtime.win_timer[win_id] = nil
  end
  if active.manual then
    state.end_manual_scroll()
  end
end

local function round(value)
  return math.floor(value + 0.5)
end

local function clamp01(value)
  return math.max(0, math.min(value, 1))
end

local function easing_at(easing, t)
  if type(easing) == 'function' then
    local ok, value = pcall(easing, t, 0, 1, 1)
    return ok and clamp01(value) or t
  end

  local easing_fn = animate.easing[easing] or animate.easing.linear
  return clamp01(easing_fn(t, 0, 1, 1))
end

local function solve_easing_time(progress, easing)
  if progress <= 0 then return 0 end
  if progress >= 1 then return 1 end
  if not easing or easing == 'linear' then return progress end

  local lo, hi = 0, 1
  for _ = 1, 12 do
    local mid = (lo + hi) / 2
    if easing_at(easing, mid) < progress then
      lo = mid
    else
      hi = mid
    end
  end

  return hi
end

local function build_intervals(total, duration, easing)
  if total <= 1 then return {} end

  local intervals = {}
  local prev_t = 0
  for i = 2, total do
    local progress = (i - 1) / (total - 1)
    local next_t = solve_easing_time(progress, easing)
    local interval = math.max(1, math.floor((next_t - prev_t) * duration + 0.5))
    intervals[#intervals + 1] = interval
    prev_t = next_t
  end

  return intervals
end

local function animation_duration(total, limit)
  local config = state.config()
  local frame_ms = math.max(1, config.frame_ms or state.defaults.frame_ms)
  local duration = frame_ms * math.max(total - 1, 1)
  return math.min(limit, duration)
end

local function step_limit_for_duration(limit)
  local config = state.config()
  local frame_ms = math.max(1, config.frame_ms or state.defaults.frame_ms)
  return math.max(1, math.floor(limit / frame_ms) + 1)
end

---@param win_id integer
function M.track_state(win_id)
  local captured = viewport.capture_state(win_id or vim.api.nvim_get_current_win())
  if captured then
    state.runtime.auto_state[captured.win_id] = captured
  end
end

---@param win_id integer
function M.track_state_partial(win_id)
  local tracked = state.runtime.auto_state[win_id or vim.api.nvim_get_current_win()]
  if not tracked or state.runtime.auto_busy[tracked.win_id] then return end

  local fresh = viewport.capture_state(tracked.win_id)
  if fresh then
    tracked.cursor = fresh.cursor
  end
end

---滚动指定窗口
---@param win_id integer 目标窗口
---@param lines integer 正数向下（C-e），负数向上（C-y）
function M.window(win_id, lines)
  if not win_id or not vim.api.nvim_win_is_valid(win_id) then return end
  if lines == 0 then return end

  stop_scroll(win_id)

  local config = state.config()
  if vim.g.neovide or not config.enabled then
    viewport.scroll_instant(win_id, lines)
    M.track_state(win_id)
    return
  end

  local direction = lines > 0
  local from_view = viewport.capture_view(win_id)
  local buf_id = vim.api.nvim_win_get_buf(win_id)
  local buf_lines = vim.api.nvim_buf_line_count(buf_id)
  local to_top = math.max(1, math.min(from_view.topline + lines, buf_lines))
  local total = math.abs(to_top - from_view.topline)
  if total < 1 then return end

  local runtime = state.runtime
  runtime.win_seq[win_id] = (runtime.win_seq[win_id] or 0) + 1
  local my_seq = runtime.win_seq[win_id]

  local duration = animation_duration(total, state.duration_limit('key_duration'))
  local intervals = build_intervals(total, duration, config.easing)
  local key = direction and '\5' or '\25'
  local scrolled = 0
  local timer = assert(uv.new_timer())

  state.begin_manual_scroll()
  runtime.win_timer[win_id] = { seq = my_seq, timer = timer, manual = true }

  local tick
  tick = function()
    vim.schedule(function()
      if my_seq ~= runtime.win_seq[win_id]
          or not vim.api.nvim_win_is_valid(win_id) then
        stop_scroll(win_id, my_seq)
        return
      end

      if not viewport.scroll_line(win_id, key) then
        stop_scroll(win_id, my_seq)
        return
      end

      state.touch_manual_scroll()
      M.track_state(win_id)

      scrolled = scrolled + 1
      if scrolled >= total then
        stop_scroll(win_id, my_seq)
        return
      end

      local current_config = state.config()
      local interval = intervals[scrolled]
        or (current_config.frame_ms or state.defaults.frame_ms)
      timer:start(interval, 0, tick)
    end)
  end

  timer:start(0, 0, tick)
end

local function build_subscrolls(total, max_steps)
  local steps = math.min(total, math.max(1, max_steps or state.defaults.auto_max_steps))
  local chunks = {}

  for i = 1, steps do
    local current = math.floor(i * total / steps)
    local previous = math.floor((i - 1) * total / steps)
    chunks[i] = math.max(1, current - previous)
  end

  return chunks
end

---@param total integer
---@return integer
function M.auto_step_count(total)
  if total <= 0 then return 0 end

  local config = state.config()
  local limit = state.duration_limit('auto_duration')
  local max_steps = math.min(
    config.auto_max_steps or state.defaults.auto_max_steps,
    step_limit_for_duration(limit)
  )

  return math.min(total, math.max(1, max_steps))
end

local function set_intermediate_cursor(from_state, to_state, step, step_count)
  local progress = step_count <= 0 and 1 or (step / step_count)
  local line = round(from_state.cursor.line
    + (to_state.cursor.line - from_state.cursor.line) * progress)
  local virtcol = round(from_state.cursor.virtcol
    + (to_state.cursor.virtcol - from_state.cursor.virtcol) * progress)
  local top, bottom = vim.fn.line('w0'), vim.fn.line('w$')
  line = math.max(top, math.min(line, bottom))

  local col = vim.fn.virtcol2col(0, line, virtcol)
  local line_end = vim.fn.virtcol({ line, '$' })
  if line_end <= virtcol then
    col = col + virtcol - line_end + 1
  end

  pcall(vim.api.nvim_win_set_cursor, 0, { line, math.max(0, col - 1) })
end

local function restore_scroll_options(target_state)
  vim.wo.scrolloff = target_state.scrolloff
  vim.wo.virtualedit = target_state.virtualedit
end

local function finish_auto_scroll(win_id, to_state)
  if vim.api.nvim_win_is_valid(win_id) then
    pcall(vim.api.nvim_win_call, win_id, function()
      vim.fn.winrestview(to_state.view)
      restore_scroll_options(to_state)
    end)
    M.track_state(win_id)
  end

  state.runtime.auto_busy[win_id] = nil
end

local function start_auto_scroll(from_state, to_state)
  local win_id = to_state.win_id
  if not vim.api.nvim_win_is_valid(win_id) then return end

  local config = state.config()
  local total = math.abs(to_state.view.topline - from_state.view.topline)
  if total < math.max(1, config.auto_min_lines or state.defaults.auto_min_lines) then
    state.runtime.auto_state[win_id] = to_state
    return
  end

  stop_scroll(win_id)
  state.runtime.auto_busy[win_id] = true

  local limit = state.duration_limit('auto_duration')
  local chunks = build_subscrolls(total, M.auto_step_count(total))
  local step_count = #chunks
  local duration = animation_duration(step_count, limit)
  local intervals = build_intervals(step_count, duration, config.easing)
  local key = from_state.view.topline < to_state.view.topline and '\5' or '\25'
  local step = 0
  local timer = assert(uv.new_timer())

  local ok = pcall(vim.api.nvim_win_call, win_id, function()
    vim.wo.scrolloff = 0
    vim.wo.virtualedit = 'all'
    vim.fn.winrestview(from_state.view)
    M.track_state(win_id)
  end)
  if not ok then
    close_timer(timer)
    state.runtime.auto_busy[win_id] = nil
    return
  end

  local tick
  tick = function()
    vim.schedule(function()
      if not state.runtime.auto_busy[win_id]
          or not vim.api.nvim_win_is_valid(win_id) then
        close_timer(timer)
        state.runtime.auto_busy[win_id] = nil
        return
      end

      step = step + 1
      local chunk = chunks[step]
      if not chunk then
        close_timer(timer)
        finish_auto_scroll(win_id, to_state)
        return
      end

      if not viewport.scroll_lines(win_id, chunk, key) then
        close_timer(timer)
        finish_auto_scroll(win_id, to_state)
        return
      end

      pcall(vim.api.nvim_win_call, win_id, function()
        set_intermediate_cursor(from_state, to_state, step, step_count)
      end)
      M.track_state(win_id)

      if step >= step_count then
        close_timer(timer)
        finish_auto_scroll(win_id, to_state)
        return
      end

      local current_config = state.config()
      local interval = intervals[step]
        or (current_config.frame_ms or state.defaults.frame_ms)
      timer:start(interval, 0, tick)
    end)
  end

  timer:start(0, 0, tick)
end

---在目标窗口执行一次跳转，并把跳转造成的视口变化转成平滑动画
---@param win_id integer 目标窗口
---@param fn fun() 要在目标窗口上下文里执行的动作
---@return boolean ok 动作是否成功执行
function M.with_view_animation(win_id, fn)
  if type(fn) ~= 'function' then return false end
  if not win_id or not vim.api.nvim_win_is_valid(win_id) then return false end

  local from_state = viewport.capture_state(win_id)
  local ok = pcall(vim.api.nvim_win_call, win_id, fn)
  local to_state = viewport.capture_state(win_id)

  if not from_state or not to_state then return ok end
  if from_state.buf_id ~= to_state.buf_id then
    M.track_state(win_id)
    return ok
  end

  local config = state.config()
  if vim.g.neovide or not config.enabled or not config.auto then
    M.track_state(win_id)
    return ok
  end

  if from_state.view.topline == to_state.view.topline then
    M.track_state(win_id)
    return ok
  end

  start_auto_scroll(from_state, to_state)
  return ok
end

---在目标窗口执行即时视口变更，并阻止 WinScrolled 把它转换成自动动画
---@param win_id integer 目标窗口
---@param fn fun() 即时视口变更
---@return boolean ok 变更是否成功执行
function M.with_auto_suppressed(win_id, fn)
  if type(fn) ~= 'function' then return false end
  if not win_id or not vim.api.nvim_win_is_valid(win_id) then return false end

  stop_scroll(win_id)
  state.runtime.auto_busy[win_id] = nil
  state.begin_manual_scroll()

  local ok = pcall(fn)

  state.end_manual_scroll()
  M.track_state(win_id)

  return ok
end

---@param args table
function M.on_win_scrolled(args)
  local config = state.config()
  if not config.enabled or not config.auto or vim.g.neovide then return end

  local win_id = tonumber(args.match) or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win_id) then return end

  local new_state = viewport.capture_state(win_id)
  if not new_state then return end

  -- scrollbind 由 Neovim 同步同组窗口；再次拆分滚动会让绑定窗口争抢 viewport
  if vim.api.nvim_get_option_value('scrollbind', { win = win_id }) then
    state.runtime.auto_state[win_id] = new_state
    return
  end

  if state.runtime.auto_busy[win_id] then
    state.runtime.auto_state[win_id] = new_state
    return
  end

  if state.auto_suppressed() then
    state.runtime.auto_state[win_id] = new_state
    return
  end

  local prev_state = state.runtime.auto_state[win_id]
  state.runtime.auto_state[win_id] = new_state
  if not prev_state then return end
  if prev_state.buf_id ~= new_state.buf_id then return end
  if prev_state.view.topline == new_state.view.topline then return end

  start_auto_scroll(prev_state, new_state)
end

return M
