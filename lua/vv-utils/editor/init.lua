-- vv-utils.editor — 编辑器通用小工具
--
-- 成员：
--   copy(text, opts?)      写系统剪贴板 + 可选通知
--   visual_range()         当前可视选区的行号范围（"start-end"，非可视模式返 nil）
--   build_path(opts?)      纯函数：按 opts 构建路径字符串，无副作用（不写剪贴板、不 notify）
--   copy_path(opts?)       build_path + copy，便捷封装

local path = require('vv-utils.path')

local M = {}

--- 把文本写入系统剪贴板，并弹出 notify 反馈（可关）
---@param text string
---@param opts? { title?: string, silent?: boolean, level?: integer }
function M.copy(text, opts)
  opts = opts or {}
  vim.fn.setreg('+', text)
  if opts.silent then return end
  vim.notify('Copied: ' .. text, opts.level or vim.log.levels.INFO, { title = opts.title or 'copy' })
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

---@class vv-utils.editor.PathOpts
---@field path? string         外部路径；不传则用当前 buffer (`expand('%:p')`)
---@field relative? boolean    相对项目根目录（path.get_root()），默认 false（绝对路径）
---@field line? boolean|integer[]  追加行号：true=自动（可视模式 visual_range / 否则光标行）；{l1,l2}=显式范围

--- 纯函数：按 opts 构建路径字符串，无副作用
---
--- 行号格式：单行 `path:42`，范围 `path:42-51`
---@param opts? vv-utils.editor.PathOpts
---@return string|nil  构建好的路径字符串；无路径时 nil
function M.build_path(opts)
  opts = opts or {}

  local p
  if opts.path and opts.path ~= '' then
    p = vim.fn.fnamemodify(opts.path, ':p')
  else
    p = vim.fn.expand('%:p')
  end
  if p == '' then return nil end

  p = path.norm(p)

  if opts.relative then
    local root = path.get_root()
    if root and root ~= '' then
      local prefix = root:sub(-1) == '/' and root or root .. '/'
      if p:sub(1, #prefix) == prefix then p = p:sub(#prefix + 1) end
    end
  end

  if opts.line then
    if type(opts.line) == 'table' then
      local l1, l2 = opts.line[1], opts.line[2]
      if l1 and l2 and l1 ~= l2 then
        if l1 > l2 then l1, l2 = l2, l1 end
        p = string.format('%s:%d-%d', p, l1, l2)
      else
        p = string.format('%s:%d', p, l1 or l2)
      end
    else
      local range = M.visual_range()
      if range then
        p = p .. ':' .. range
      else
        p = p .. ':' .. vim.api.nvim_win_get_cursor(0)[1]
      end
    end
  end

  return p
end

---@class vv-utils.editor.CopyPathOpts : vv-utils.editor.PathOpts
---@field notify? boolean   是否 notify 反馈，默认 true
---@field title? string     notify 的 title，默认 'copy'

--- build_path + copy，便捷封装
---@param opts? vv-utils.editor.CopyPathOpts
---@return string|nil
function M.copy_path(opts)
  opts = opts or {}
  local p = M.build_path(opts)
  if not p then return nil end
  M.copy(p, { silent = opts.notify == false, title = opts.title })
  return p
end

return M
