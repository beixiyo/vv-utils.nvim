-- 终端拖拽路径检测 + handler 分发
--
-- 两条进入路径，统一走路径 handler 分发：
--   1. bracketed paste（覆写 vim.paste）：拖入的文件以「粘贴文本」形式到达，无坐标。
--      pos = nil。tmux / 不支持 DnD 协议的终端走这条。
--   2. kitty DnD 协议（OSC 72，kitty ≥ 0.47）：拖入带落点 cell 坐标 + 拖拽移动事件流。
--      pos = { x, y, op }（屏幕 cell，原点左上）。需 nvim 直接跑在 kitty 下（不挂 tmux，
--      tmux 不透传入站 OSC）。启动时探测，支持才 opt-in；不支持自动回退路径 1。
--
-- handler 签名 fun(paths, pos) → 返回 true 表示已消费。pos 为 nil 时是无坐标的粘贴落点，
-- 由 handler 自行决定（如复制到光标目录）；pos 非 nil 时按落点坐标处理。
-- on_drag(cb) 订阅拖拽移动 / 离开事件，用于实时高亮落点（仅 DnD 协议下触发）。

local dispatcher = require('vv-utils.drop.dispatcher')
local kitty = require('vv-utils.drop.kitty')
local paths = require('vv-utils.drop.paths')

local M = {
  detect_paths = paths.detect_paths,
  register = dispatcher.register,
  on_drag = dispatcher.on_drag,
}

local original_paste

--- 安装 vim.paste 拦截 + kitty DnD 协议
---@param opts? vv-utils.drop.Opts
function M.setup(opts)
  opts = opts or {}

  if not original_paste then
    original_paste = vim.paste

    vim.paste = function(lines, phase)
      if phase ~= -1 then
        return original_paste(lines, phase)
      end

      local detected_paths = paths.detect_paths(lines)
      if not detected_paths then
        return original_paste(lines, phase)
      end

      if dispatcher.dispatch(detected_paths, nil) then return false end
      return original_paste(lines, phase)
    end
  end

  if opts.kitty_dnd ~= false then
    kitty.setup(dispatcher.dispatch, dispatcher.fire_drag)
  end
end

---@class vv-utils.drop.Opts
---@field kitty_dnd? boolean 是否启用 Kitty OSC 72 落点协议 @default true

---@class vv-utils.drop.Position kitty DnD 落点（屏幕 cell，原点左上）
---@field x integer 横坐标 @default 0
---@field y integer 纵坐标 @default 0
---@field op integer 允许的操作：1=copy 2=move 3=either @default 3

---@class vv-utils.drop.DragEvent 拖拽过程事件
---@field kind 'move'|'leave' 事件类型 @default 'move'
---@field x integer? kind='move' 时为当前 cell x @default nil
---@field y integer? kind='move' 时为当前 cell y @default nil
---@field op integer? 允许的操作 @default nil

return M
