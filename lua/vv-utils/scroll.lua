-- vv-utils.scroll — 跨窗口平滑滚动
-- 基于 vv-utils.animate 补间引擎驱动，支持 easing + 连按去重
--
-- 用法：
--   local scroll = require('vv-utils.scroll')
--   scroll.window(win_id, 5)   -- 向下 5 行
--   scroll.window(win_id, -3)  -- 向上 3 行
--
-- 焦点策略：滚动一律通过 `nvim_win_call` 在目标窗上下文里执行 `normal! N<C-e>`，
-- 全程不改全局 current win，从根本上避免跨窗连按时焦点卡在目标窗

local animate = require('vv-utils.animate')

local M = {}

local defaults = {
  enabled = true,
  duration = 280,
  easing = 'outQuad',
  step = 5,
  mouse_step = 7,
}

local config = vim.deepcopy(defaults)

---@class vv-utils.scroll.Opts
---@field enabled?    boolean 全局开关；false=走原生跳转 @default true
---@field duration?   integer 补间动画持续时长（ms） @default 280
---@field easing?     string  缓动函数（linear/outQuad/outCubic/inQuad/inOutQuad） @default 'outQuad'
---@field step?       integer 键盘 <C-e>/<C-y> 无 count 前缀时每次滚动行数 @default 5
---@field mouse_step? integer 鼠标滚轮每次滚动行数（写入原生 mousescroll，0=不接管） @default 7

function M.setup(opts)
  config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
  M._install_scroll_keymaps()
end

function M.get_config()
  return vim.deepcopy(config)
end

-- 每个窗口独立 seq，防止不同窗口互相取消
local win_seq = {}

local scroll_keymaps_installed = false

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

---滚动指定窗口
---@param win_id integer  目标窗口
---@param lines integer   正数向下（C-e），负数向上（C-y）
function M.window(win_id, lines)
  if not win_id or not vim.api.nvim_win_is_valid(win_id) then return end
  if lines == 0 then return end

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
  local anim_duration = math.min(config.duration, math.max(60, 60 * total))

  local key = direction and '\5' or '\25'
  local last_scrolled = 0

  animate.add(0, total, function(value)
    -- 被新的滚动抢占 / 窗口已关 → 静默退出（不需恢复焦点，全程没切过）
    if my_seq ~= win_seq[win_id] then return end
    if not vim.api.nvim_win_is_valid(win_id) then return end

    local target = math.floor(value + 0.5)
    local scroll_now = target - last_scrolled
    if scroll_now > 0 then
      -- 仅在真正滚成功后推进 last_scrolled，避免边界报错导致计数失同步
      if scroll_lines(win_id, scroll_now, key) then
        last_scrolled = target
      end
    end
  end, {
    id = ('vv_scroll_%d'):format(win_id),
    duration = { total = anim_duration },
    easing = config.easing,
    int = true,
  })
end

---全局滚动键映射（键盘 C-e/C-y）
function M._install_scroll_keymaps()
  if scroll_keymaps_installed then return end
  scroll_keymaps_installed = true

  -- 鼠标滚轮交给原生 mousescroll：visual/insert 模式下用 normal! 会被踢出当前模式，
  -- 而原生滚轮本就能在任意模式滚动鼠标所在窗，无需重映射
  if config.mouse_step and config.mouse_step > 0 then
    vim.opt.mousescroll = ('ver:%d,hor:6'):format(config.mouse_step)
  end

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
