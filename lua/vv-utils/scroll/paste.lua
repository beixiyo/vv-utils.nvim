-- vv-utils.scroll.paste — 粘贴期间抑制自动滚动动画
--
-- 为什么需要：auto 动画的每一帧由 viewport.scroll_lines 里的
-- `vim.cmd('normal! N<C-e>')` 驱动，而 `normal!` 会重入 Neovim 的输入处理
-- 终端括号粘贴（bracketed paste）正在分块读取字节流时被重入，chunk 边界
-- 会切进多字节字符中间，粘贴结果出现字符残缺 + 等宽空格填充
-- 粘贴过程本身没有做滚动动画的必要，全程抑制即可
--
-- 生命周期：install/uninstall 成对且幂等；install 只包装一层 vim.paste，
-- uninstall 仅在 vim.paste 仍是本模块安装的那层时才恢复

local state = require('vv-utils.scroll.state')

local uv = vim.uv or vim.loop

local M = {}

-- 粘贴可能因异常、取消或 UI 中断而收不到结束 phase；兜底 timer 防止抑制计数泄漏
-- （泄漏会让 auto_suppressed() 永远为真，自动动画从此静默失效）
local GUARD_MS = 2000

local pasting = false
local guard ---@type uv.uv_timer_t?
local handler ---@type fun(lines: string[], phase: integer): boolean?
local previous ---@type fun(lines: string[], phase: integer): boolean?

local function stop_guard()
  if not guard then return end
  if guard:is_active() then guard:stop() end
  if not guard:is_closing() then guard:close() end
  guard = nil
end

local function arm_guard()
  stop_guard()
  guard = assert(uv.new_timer())
  guard:start(GUARD_MS, 0, vim.schedule_wrap(function()
    M.finish()
  end))
end

--- 进入粘贴：停掉在跑的动画并打开抑制。重复调用只续期兜底 timer
function M.start()
  if pasting then
    arm_guard()
    return
  end

  pasting = true
  -- cancel_all 内部会 reset_runtime（清零 manual_scroll_count），必须先取消再计数
  require('vv-utils.scroll.animation').cancel_all()
  state.begin_manual_scroll()
  arm_guard()
end

--- 离开粘贴：关闭抑制。未处于粘贴态时为 no-op
function M.finish()
  if not pasting then return end

  pasting = false
  stop_guard()
  state.end_manual_scroll()
end

---@return boolean
function M.active()
  return pasting
end

function M.install()
  if handler and vim.paste == handler then return end

  previous = vim.paste
  handler = function(lines, phase)
    -- phase: 1=首块 2=续块 3=末块 -1=单块一次完成
    -- 续块同样进入：start() 在粘贴态下只续期兜底 timer，慢速大粘贴才不会被误判卡住
    if phase == 1 or phase == 2 or phase == -1 then M.start() end

    local ok, res = pcall(previous, lines, phase)

    -- 结束、被取消（返回 false）或抛错都要解除抑制，避免计数泄漏
    if phase == 3 or phase == -1 or not ok or res == false then M.finish() end
    if not ok then error(res, 0) end

    return res
  end
  vim.paste = handler
end

function M.uninstall()
  M.finish()

  if handler and vim.paste == handler and previous then
    vim.paste = previous
  end
  handler, previous = nil, nil
end

return M
