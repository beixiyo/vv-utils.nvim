-- vv-utils.scroll — 跨窗口平滑滚动
-- 逐行 timer 调度，避免补间取整后一次跳多行导致的顿挫
--
-- 焦点策略：滚动通过 nvim_win_call 在目标窗口上下文里执行，全程不改变当前窗口

local animation = require('vv-utils.scroll.animation')
local input = require('vv-utils.scroll.input')
local state = require('vv-utils.scroll.state')

local M = {}

---@class vv-utils.scroll.Opts
---@field enabled? boolean 全局开关；false=走原生跳转 @default true
---@field auto? boolean 自动监听 WinScrolled，处理 gg/G/搜索等跳转动画 @default true
---@field auto_min_lines? integer 自动动画最小滚动距离，避免鼠标小步滚动被接管 @default 4
---@field auto_max_steps? integer 自动动画最大分步数，避免大跳转产生过多 timer @default 10
---@field duration? integer 默认动画最长持续时间（ms） @default 180
---@field key_duration? integer 键盘滚动动画最长持续时间（ms） @default 120
---@field auto_duration? integer gg/G/搜索等自动跳转动画最长持续时间（ms） @default 108
---@field easing? string 缓动函数（linear/outQuad/outCubic/inQuad/inOutQuad） @default 'linear'
---@field step? integer 键盘 <C-e>/<C-y> 无 count 前缀时每次滚动行数 @default 5
---@field frame_ms? integer 逐行滚动的目标帧间隔；值越小越贴近原生快速滚动 @default 12
---@field mouse? 'native'|'smooth' 鼠标滚轮策略：native=不接管，smooth=映射到平滑滚动 @default 'native'
---@field mouse_step? integer 鼠标滚轮每次滚动行数（0=不接管） @default 3

---@param opts? vv-utils.scroll.Opts
function M.setup(opts)
  state.setup(opts)
  M._install_scroll_keymaps()
end

---@return vv-utils.scroll.Opts
function M.get_config()
  return state.get_config()
end

M.window = animation.window
M.mouse = input.mouse
M.with_view_animation = animation.with_view_animation
M.with_auto_suppressed = animation.with_auto_suppressed

function M._auto_suppressed()
  return state.auto_suppressed()
end

---@param total integer
---@return integer
function M._auto_step_count(total)
  return animation.auto_step_count(total)
end

function M._install_scroll_keymaps()
  input.install()
end

return M
