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

local config = vim.deepcopy(defaults)

---@class vv-utils.scroll.Opts
---@field enabled?    boolean 全局开关；false=走原生跳转 @default true
---@field auto?       boolean 自动监听 WinScrolled，处理 gg/G/搜索等跳转动画 @default true
---@field auto_min_lines? integer 自动动画最小滚动距离，避免鼠标小步滚动被接管 @default 4
---@field auto_max_steps? integer 自动动画最大分步数，避免大跳转产生过多 timer @default 10
---@field duration?   integer 默认动画最长持续时间（ms） @default 180
---@field key_duration? integer 键盘滚动动画最长持续时间（ms） @default 120
---@field auto_duration? integer gg/G/搜索等自动跳转动画最长持续时间（ms） @default 108
---@field easing?     string  缓动函数（linear/outQuad/outCubic/inQuad/inOutQuad） @default 'linear'
---@field step?       integer 键盘 <C-e>/<C-y> 无 count 前缀时每次滚动行数 @default 5
---@field frame_ms?   integer 逐行滚动的目标帧间隔；值越小越贴近原生快速滚动 @default 12
---@field mouse?      '"native"'|'"smooth"' 鼠标滚轮策略：native=不接管，smooth=映射到平滑滚动 @default 'native'
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
local auto_state = {}
local auto_busy = {}
local manual_scroll_count = 0
local manual_suppress_until = 0

local scroll_keymaps_installed = false
local augroup

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
  if state.manual then
    manual_scroll_count = math.max(0, manual_scroll_count - 1)
    manual_suppress_until = uv.now() + math.max(40, (config.frame_ms or defaults.frame_ms) * 3)
  end
end

local function round(value)
  return math.floor(value + 0.5)
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

local function duration_limit(name)
  local value = config[name]
  if type(value) == 'number' then
    return math.max(0, value)
  end

  local fallback = config.duration or defaults.duration
  return math.max(0, fallback)
end

local function animation_duration(total, limit)
  local frame_ms = math.max(1, config.frame_ms or defaults.frame_ms)
  local duration = frame_ms * math.max(total - 1, 1)
  return math.min(limit, duration)
end

local function auto_suppressed()
  return manual_scroll_count > 0 or uv.now() < manual_suppress_until
end

function M._auto_suppressed()
  return auto_suppressed()
end

local function step_limit_for_duration(limit)
  local frame_ms = math.max(1, config.frame_ms or defaults.frame_ms)
  return math.max(1, math.floor(limit / frame_ms) + 1)
end

local function mouse_target_win()
  local ok, pos = pcall(vim.fn.getmousepos)
  if ok and pos and pos.winid and pos.winid ~= 0 and vim.api.nvim_win_is_valid(pos.winid) then
    return pos.winid
  end

  return vim.api.nvim_get_current_win()
end

local function capture_state(win_id)
  if not win_id or not vim.api.nvim_win_is_valid(win_id) then return nil end

  local ok, state = pcall(vim.api.nvim_win_call, win_id, function()
    return {
      buf_id = vim.api.nvim_get_current_buf(),
      win_id = win_id,
      view = vim.fn.winsaveview(),
      cursor = { line = vim.fn.line('.'), virtcol = vim.fn.virtcol('.') },
      scrolloff = vim.wo.scrolloff,
      virtualedit = vim.wo.virtualedit,
    }
  end)

  return ok and state or nil
end

local function track_state(win_id)
  local state = capture_state(win_id or vim.api.nvim_get_current_win())
  if state then
    auto_state[state.win_id] = state
  end
end

local function track_state_partial(win_id)
  local state = auto_state[win_id or vim.api.nvim_get_current_win()]
  if not state or auto_busy[state.win_id] then return end

  local fresh = capture_state(state.win_id)
  if not fresh then return end

  state.cursor = fresh.cursor
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
    track_state(win_id)
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
  local anim_duration = animation_duration(total, duration_limit('key_duration'))
  local intervals = build_intervals(total, anim_duration, config.easing)
  local key = direction and '\5' or '\25'
  local scrolled = 0
  local timer = assert(uv.new_timer())

  manual_scroll_count = manual_scroll_count + 1
  manual_suppress_until = uv.now() + math.max(40, (config.frame_ms or defaults.frame_ms) * 3)
  win_timer[win_id] = { seq = my_seq, timer = timer, manual = true }

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
      manual_suppress_until = uv.now() + math.max(40, (config.frame_ms or defaults.frame_ms) * 3)
      track_state(win_id)

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

local function build_subscrolls(total, max_steps)
  local steps = math.min(total, math.max(1, max_steps or defaults.auto_max_steps))
  local chunks = {}

  for i = 1, steps do
    local current = math.floor(i * total / steps)
    local previous = math.floor((i - 1) * total / steps)
    chunks[i] = math.max(1, current - previous)
  end

  return chunks
end

function M._auto_step_count(total)
  if total <= 0 then return 0 end

  local limit = duration_limit('auto_duration')
  local max_steps = math.min(
    config.auto_max_steps or defaults.auto_max_steps,
    step_limit_for_duration(limit)
  )

  return math.min(total, math.max(1, max_steps))
end

local function set_intermediate_cursor(from_state, to_state, step, step_count)
  local progress = step_count <= 0 and 1 or (step / step_count)
  local line = round(from_state.cursor.line + (to_state.cursor.line - from_state.cursor.line) * progress)
  local virtcol = round(from_state.cursor.virtcol + (to_state.cursor.virtcol - from_state.cursor.virtcol) * progress)
  local top, bottom = vim.fn.line('w0'), vim.fn.line('w$')
  line = math.max(top, math.min(line, bottom))

  local col = vim.fn.virtcol2col(0, line, virtcol)
  local line_end = vim.fn.virtcol({ line, '$' })
  if line_end <= virtcol then
    col = col + virtcol - line_end + 1
  end

  pcall(vim.api.nvim_win_set_cursor, 0, { line, math.max(0, col - 1) })
end

local function restore_scroll_options(state)
  vim.wo.scrolloff = state.scrolloff
  vim.wo.virtualedit = state.virtualedit
end

local function finish_auto_scroll(win_id, to_state)
  if vim.api.nvim_win_is_valid(win_id) then
    pcall(vim.api.nvim_win_call, win_id, function()
      vim.fn.winrestview(to_state.view)
      restore_scroll_options(to_state)
    end)
    track_state(win_id)
  end

  auto_busy[win_id] = nil
end

local function start_auto_scroll(from_state, to_state)
  local win_id = to_state.win_id
  if not vim.api.nvim_win_is_valid(win_id) then return end

  local total = math.abs(to_state.view.topline - from_state.view.topline)
  if total < math.max(1, config.auto_min_lines or defaults.auto_min_lines) then
    auto_state[win_id] = to_state
    return
  end

  stop_scroll(win_id)
  auto_busy[win_id] = true

  local limit = duration_limit('auto_duration')
  local chunks = build_subscrolls(total, M._auto_step_count(total))
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
    track_state(win_id)
  end)
  if not ok then
    close_timer(timer)
    auto_busy[win_id] = nil
    return
  end

  local tick
  tick = function()
    vim.schedule(function()
      if not auto_busy[win_id] or not vim.api.nvim_win_is_valid(win_id) then
        close_timer(timer)
        auto_busy[win_id] = nil
        return
      end

      step = step + 1
      local chunk = chunks[step]
      if not chunk then
        close_timer(timer)
        finish_auto_scroll(win_id, to_state)
        return
      end

      local scrolled = scroll_lines(win_id, chunk, key)
      if not scrolled then
        close_timer(timer)
        finish_auto_scroll(win_id, to_state)
        return
      end

      pcall(vim.api.nvim_win_call, win_id, function()
        set_intermediate_cursor(from_state, to_state, step, step_count)
      end)
      track_state(win_id)

      if step >= step_count then
        close_timer(timer)
        finish_auto_scroll(win_id, to_state)
        return
      end

      local interval = intervals[step] or (config.frame_ms or defaults.frame_ms)
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

  local from_state = capture_state(win_id)
  local ok = pcall(vim.api.nvim_win_call, win_id, fn)
  local to_state = capture_state(win_id)

  if not from_state or not to_state then return ok end
  if from_state.buf_id ~= to_state.buf_id then
    track_state(win_id)
    return ok
  end

  if vim.g.neovide or not config.enabled or not config.auto then
    track_state(win_id)
    return ok
  end

  if from_state.view.topline == to_state.view.topline then
    track_state(win_id)
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
  auto_busy[win_id] = nil

  local suppress_ms = math.max(40, (config.frame_ms or defaults.frame_ms) * 3)
  manual_scroll_count = manual_scroll_count + 1
  manual_suppress_until = uv.now() + suppress_ms

  local ok = pcall(fn)

  manual_scroll_count = math.max(0, manual_scroll_count - 1)
  manual_suppress_until = uv.now() + suppress_ms
  track_state(win_id)

  return ok
end

local function on_win_scrolled(args)
  if not config.enabled or not config.auto or vim.g.neovide then return end

  local win_id = tonumber(args.match) or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win_id) then return end

  local new_state = capture_state(win_id)
  if not new_state then return end

  -- scrollbind 窗口由 Neovim 负责和同组窗口同步。这里再把一次滚动拆成
  -- 自动动画，会和绑定同步互相抢 viewport，典型表现是 diff 双栏鼠标滚动时上下拉扯
  if vim.api.nvim_get_option_value('scrollbind', { win = win_id }) then
    auto_state[win_id] = new_state
    return
  end

  if auto_busy[win_id] then
    auto_state[win_id] = new_state
    return
  end

  if auto_suppressed() then
    auto_state[win_id] = new_state
    return
  end

  local prev_state = auto_state[win_id]
  auto_state[win_id] = new_state
  if not prev_state then return end
  if prev_state.buf_id ~= new_state.buf_id then return end
  if prev_state.view.topline == new_state.view.topline then return end

  start_auto_scroll(prev_state, new_state)
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

  if config.mouse == 'smooth' and not vim.g.neovide and config.enabled then
    M.window(target_win, lines)
  else
    scroll_instant(target_win, lines)
    track_state(target_win)
  end

  return true
end

local mouse_modes = { 'n', 'x', 'i' }
local mouse_keys = {
  { lhs = '<ScrollWheelDown>', dir = 'down', desc = 'vv-scroll: mouse scroll down' },
  { lhs = '<ScrollWheelUp>', dir = 'up', desc = 'vv-scroll: mouse scroll up' },
}

local function del_mouse_keymap(mode, lhs)
  local map = vim.fn.maparg(lhs, mode, false, true)
  if map and map.desc and tostring(map.desc):match('^vv%-scroll: mouse') then
    pcall(vim.keymap.del, mode, lhs)
  end
end

local function sync_mouse_keymaps()
  if config.mouse ~= 'smooth' then
    for _, key in ipairs(mouse_keys) do
      for _, mode in ipairs(mouse_modes) do
        del_mouse_keymap(mode, key.lhs)
      end
    end
    return
  end

  for _, key in ipairs(mouse_keys) do
    vim.keymap.set(mouse_modes, key.lhs, function()
      M.mouse(key.dir)
    end, { desc = key.desc })
  end
end

local function install_autocmds()
  augroup = vim.api.nvim_create_augroup('VVUtilsScroll', { clear = true })

  vim.api.nvim_create_autocmd('WinScrolled', {
    group = augroup,
    callback = on_win_scrolled,
    desc = 'vv-scroll: animate viewport jumps',
  })

  vim.api.nvim_create_autocmd({ 'BufEnter', 'WinEnter' }, {
    group = augroup,
    callback = function()
      vim.schedule(function()
        if vim.api.nvim_get_current_win() then
          track_state(vim.api.nvim_get_current_win())
        end
      end)
    end,
    desc = 'vv-scroll: track viewport state',
  })

  vim.api.nvim_create_autocmd('CursorMoved', {
    group = augroup,
    callback = function()
      local win_id = vim.api.nvim_get_current_win()
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(win_id) then
          track_state_partial(win_id)
        end
      end)
    end,
    desc = 'vv-scroll: track cursor for viewport animation',
  })

  track_state(vim.api.nvim_get_current_win())
end

---全局滚动键映射（键盘 C-e/C-y）
function M._install_scroll_keymaps()
  if config.mouse_step and config.mouse_step > 0 then
    vim.opt.mousescroll = ('ver:%d,hor:6'):format(config.mouse_step)
  end

  sync_mouse_keymaps()
  install_autocmds()

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
end

return M
