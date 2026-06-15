-- vv-utils.scroll — 跨窗口平滑滚动
-- 逐行 timer 调度，避免补间取整后一次跳多行导致的顿挫
--
-- 用法：
--   local scroll = require('vv-utils.scroll')
--   scroll.window(win_id, 5)   -- 向下 5 行
--   scroll.window(win_id, -3)  -- 向上 3 行
--   scroll.mouse('down')       -- 滚动鼠标所在窗口
--
-- 焦点策略：滚动一律通过 `nvim_win_call` 在目标窗上下文里执行 `normal! N<C-e>`，
-- 全程不改全局 current win，从根本上避免跨窗连按时焦点卡在目标窗

local animate = require('vv-utils.animate')
local uv = vim.uv or vim.loop

local M = {}

local defaults = {
  enabled = true,
  duration = 280,
  easing = 'linear',
  step = 5,
  frame_ms = 12,
  mouse_step = 3,
}

local config = vim.deepcopy(defaults)

---@class vv-utils.scroll.Opts
---@field enabled?    boolean 全局开关；false=走原生跳转 @default true
---@field duration?   integer 单次动画最长持续时间（ms） @default 280
---@field easing?     string  缓动函数（linear/outQuad/outCubic/inQuad/inOutQuad） @default 'linear'
---@field step?       integer 键盘 <C-e>/<C-y> 无 count 前缀时每次滚动行数 @default 5
---@field frame_ms?   integer 逐行滚动的目标帧间隔；值越小越贴近原生快速滚动 @default 12
---@field mouse_step? integer 鼠标滚轮每次滚动行数（0=不接管） @default 3

function M.setup(opts)
  config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
  M._install_scroll_keymaps()
end

function M.get_config()
  return vim.deepcopy(config)
end

-- 每个窗口独立 seq，防止不同窗口互相取消
local win_seq = {}
local win_timer = {}

local scroll_keymaps_installed = false

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
  local state = win_timer[win_id]
  if not state then return end
  if seq and state.seq ~= seq then return end

  close_timer(state.timer)
  if win_timer[win_id] == state then
    win_timer[win_id] = nil
  end
end

-- 在目标窗上下文里同步滚 N 行；不改全局 current win
local function scroll_lines(win_id, n, key)
  return pcall(vim.api.nvim_win_call, win_id, function()
    vim.cmd(('normal! %d%s'):format(n, key))
  end)
end

local function scroll_instant(win_id, lines)
  local key = lines > 0 and '\5' or '\25'
  scroll_lines(win_id, math.abs(lines), key)
end

local function capture_view(win_id)
  return vim.api.nvim_win_call(win_id, function()
    return vim.fn.winsaveview()
  end)
end

local function view_moved(before, after)
  return before.topline ~= after.topline
    or before.topfill ~= after.topfill
    or before.skipcol ~= after.skipcol
end

local function scroll_line(win_id, key)
  local before = capture_view(win_id)
  if not scroll_lines(win_id, 1, key) then return false end

  local after = capture_view(win_id)
  return view_moved(before, after)
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

local function animation_duration(total)
  local frame_ms = math.max(1, config.frame_ms or defaults.frame_ms)
  local duration = frame_ms * math.max(total - 1, 1)
  return math.min(config.duration, duration)
end

local function mouse_target_win()
  local ok, pos = pcall(vim.fn.getmousepos)
  if ok and pos and pos.winid and pos.winid ~= 0 and vim.api.nvim_win_is_valid(pos.winid) then
    return pos.winid
  end

  return vim.api.nvim_get_current_win()
end

---滚动指定窗口
---@param win_id integer  目标窗口
---@param lines integer   正数向下（C-e），负数向上（C-y）
function M.window(win_id, lines)
  if not win_id or not vim.api.nvim_win_is_valid(win_id) then return end
  if lines == 0 then return end

  stop_scroll(win_id)

  -- Neovide 自带 GPU 合成动画；或全局关闭时 → 原生跳转
  if vim.g.neovide or not config.enabled then
    scroll_instant(win_id, lines)
    return
  end

  local direction = lines > 0

  local from_view = capture_view(win_id)
  local buf_id = vim.api.nvim_win_get_buf(win_id)
  local buf_lines = vim.api.nvim_buf_line_count(buf_id)
  local to_top = math.max(1, math.min(from_view.topline + lines, buf_lines))
  local total = math.abs(to_top - from_view.topline)
  if total < 1 then return end

  win_seq[win_id] = (win_seq[win_id] or 0) + 1
  local my_seq = win_seq[win_id]

  -- duration 按距离缩放：小跳快，大跳沿用默认
  local anim_duration = animation_duration(total)
  local intervals = build_intervals(total, anim_duration, config.easing)
  local key = direction and '\5' or '\25'
  local scrolled = 0
  local timer = assert(uv.new_timer())

  win_timer[win_id] = { seq = my_seq, timer = timer }

  local tick
  tick = function()
    vim.schedule(function()
      -- 被新的滚动抢占 / 窗口已关 → 静默退出（不需恢复焦点，全程没切过）
      if my_seq ~= win_seq[win_id] then
        stop_scroll(win_id, my_seq)
        return
      end
      if not vim.api.nvim_win_is_valid(win_id) then
        stop_scroll(win_id, my_seq)
        return
      end

      if not scroll_line(win_id, key) then
        stop_scroll(win_id, my_seq)
        return
      end

      scrolled = scrolled + 1
      if scrolled >= total then
        stop_scroll(win_id, my_seq)
        return
      end

      local interval = intervals[scrolled] or (config.frame_ms or defaults.frame_ms)
      timer:start(interval, 0, tick)
    end)
  end

  timer:start(0, 0, tick)
end

---按鼠标滚轮方向滚动鼠标所在窗口
---@param direction '"up"'|'"down"'
---@param win_id? integer 显式目标窗口；不传时使用鼠标所在窗口
---@return boolean handled 是否已接管滚动
function M.mouse(direction, win_id)
  local step = config.mouse_step or defaults.mouse_step
  if step <= 0 then return false end

  local target_win = win_id or mouse_target_win()
  local lines = direction == 'up' and -step or step
  M.window(target_win, lines)
  return true
end

---全局滚动键映射（键盘 C-e/C-y）
function M._install_scroll_keymaps()
  if config.mouse_step and config.mouse_step > 0 then
    vim.opt.mousescroll = ('ver:%d,hor:6'):format(config.mouse_step)
  end

  if scroll_keymaps_installed then return end
  scroll_keymaps_installed = true

  -- 无 count → 默认 step 行；有 count（如 10<C-e>）→ 按 count
  local function count_lines()
    return vim.v.count > 0 and vim.v.count or config.step
  end

  -- normal + visual 都接：visual 下 nvim_win_call + normal! 实测保持 v 模式、选区跟随
  vim.keymap.set({ 'n', 'x' }, '<C-e>', function()
    M.window(vim.api.nvim_get_current_win(), count_lines())
  end, { desc = 'vv-scroll: scroll down' })

  vim.keymap.set({ 'n', 'x' }, '<C-y>', function()
    M.window(vim.api.nvim_get_current_win(), -count_lines())
  end, { desc = 'vv-scroll: scroll up' })

  vim.keymap.set({ 'n', 'x', 'i' }, '<ScrollWheelDown>', function()
    M.mouse('down')
  end, { desc = 'vv-scroll: mouse scroll down' })

  vim.keymap.set({ 'n', 'x', 'i' }, '<ScrollWheelUp>', function()
    M.mouse('up')
  end, { desc = 'vv-scroll: mouse scroll up' })
end

return M
