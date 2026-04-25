-- vv-utils.editor — 编辑器通用小工具
--
-- 目前只有两个成员：
--   copy(text, opts?)    写系统剪贴板 + 可选通知
--   visual_range()       当前可视选区的行号范围（"start-end" 字串，不在 V/v/<C-v> 时返 nil）

local M = {}

--- 把文本写入系统剪贴板，并弹出 notify 反馈（可关）
---@param text string
---@param opts? { title?: string, silent?: boolean, level?: integer }
function M.copy(text, opts)
  opts = opts or {}
  vim.fn.setreg('+', text)
  if opts.silent then return end
  vim.notify('已复制: ' .. text, opts.level or vim.log.levels.INFO, { title = opts.title or 'copy' })
end

--- 当前可视选区的行号范围（normal 模式返回 nil）
--- 返回 "start-end"：1-based 行号，start ≤ end
---@return string|nil
function M.visual_range()
  local mode = vim.fn.mode()
  if not (mode:match('v') or mode:match('V') or mode == '\22') then return nil end
  local s, e = vim.fn.line('v'), vim.fn.line('.')
  if s > e then s, e = e, s end
  return string.format('%d-%d', s, e)
end

return M
