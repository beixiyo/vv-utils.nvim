-- vv-utils.format — 中英文排版与行尾清理
--
-- 算法对齐 https://github.com/beixiyo/vsc-word-space
--
-- 纯函数：
--   add_spaces_around_english(text)  中英文之间智能加空格
--   clean_line_trailing(text)        清理每行行尾的中文句号 / 感叹号 / 问号 / 多余空白
--
-- Buffer 副作用（Visual 有选区时只处理选区，否则处理全文）：
--   add_spaces()       对当前 buffer 应用加空格
--   clean_trailing()   对当前 buffer 应用行尾清理

local M = {}

-- 中文范围：CJK Unified Ideographs 主区段（U+4E00-U+9FA5）
-- 与 vsc-word-space 原版 U+4E00-U+9FFF 略小，但 U+9FA6+ 在中文排版中几乎不出现，无实际影响
--
-- 左侧：中文；右侧：(允许的前缀符号*)英数。前缀符号：@#$¥€£+_-*~`[
local LEFT_PATTERN  = [=[\([一-龥]\)\([@#$¥€£+_\-*~`[]*[A-Za-z0-9]\)]=]
-- 左侧：英数(允许的后缀符号*)；右侧：中文。后缀符号：+-%‰°_*~`)]
local RIGHT_PATTERN = [=[\([A-Za-z0-9][+\-%‰°_*~`)\]]*\)\([一-龥]\)]=]

-- 行尾清理：连续的 [。！？] 加可选空白；或纯空白
local TRAILING_PATTERN = [[\%(\%([。！？][ \t]*\)\+\|[ \t]\+\)$]]

--- 中英文之间智能加空格（前缀 / 后缀符号会被推到外侧，保留 markdown 格式如 **bold**）
---@param text string
---@return string
function M.add_spaces_around_english(text)
  text = vim.fn.substitute(text, LEFT_PATTERN, [[\1 \2]], 'g')
  text = vim.fn.substitute(text, RIGHT_PATTERN, [[\1 \2]], 'g')
  return text
end

--- 删除每行行尾的中文句号 / 感叹号 / 问号 + 多余空白；无句号时仅删空白
---@param text string
---@return string
function M.clean_line_trailing(text)
  local lines = vim.split(text, '\n', { plain = true })
  for i, line in ipairs(lines) do
    lines[i] = vim.fn.substitute(line, TRAILING_PATTERN, '', '')
  end
  return table.concat(lines, '\n')
end

-- 取当前 visual 选区的行号范围 [s_row, e_row]（1-based, inclusive）
-- 返回 nil 表示当前不在 visual 模式
---@return integer?, integer?
local function visual_line_range()
  local mode = vim.fn.mode()
  if not (mode == 'v' or mode == 'V' or mode == '\22') then return nil end
  -- 退出可视模式以更新 '< '> 标记
  vim.cmd([[execute "normal! \<Esc>"]])
  local s = vim.api.nvim_buf_get_mark(0, '<')[1]
  local e = vim.api.nvim_buf_get_mark(0, '>')[1]
  if s > e then s, e = e, s end
  return s, e
end

--- 把 transform 应用到当前 buffer
--- 优先级：显式 opts.range > visual 选区嗅探 > 全文
---@param transform fun(text: string): string
---@param opts? { range?: integer[], msg_changed?: string, msg_unchanged?: string, silent?: boolean }
function M.apply_to_buffer(transform, opts)
  opts = opts or {}

  local from_row, to_row
  if opts.range then
    from_row, to_row = opts.range[1] - 1, opts.range[2]
  else
    local s_row, e_row = visual_line_range()
    if s_row then
      from_row, to_row = s_row - 1, e_row
    else
      from_row, to_row = 0, -1
    end
  end

  local lines = vim.api.nvim_buf_get_lines(0, from_row, to_row, false)
  local original = table.concat(lines, '\n')
  local processed = transform(original)

  if processed == original then
    if not opts.silent then
      vim.notify(opts.msg_unchanged or '没有需要处理的内容', vim.log.levels.INFO, { title = 'vv-utils.format' })
    end
    return false
  end

  local new_lines = vim.split(processed, '\n', { plain = true })
  vim.api.nvim_buf_set_lines(0, from_row, to_row, false, new_lines)

  if not opts.silent and opts.msg_changed then
    vim.notify(opts.msg_changed, vim.log.levels.INFO, { title = 'vv-utils.format' })
  end
  return true
end

--- 当前 buffer：中英文之间加空格
---@param opts? { range?: integer[], silent?: boolean }
function M.add_spaces(opts)
  return M.apply_to_buffer(M.add_spaces_around_english, vim.tbl_extend('keep', opts or {}, {
    msg_changed = '已为中英文之间添加空格',
    msg_unchanged = '没有找到需要处理的文本',
  }))
end

--- 当前 buffer：清理行尾句号与多余空白
---@param opts? { range?: integer[], silent?: boolean }
function M.clean_trailing(opts)
  return M.apply_to_buffer(M.clean_line_trailing, vim.tbl_extend('keep', opts or {}, {
    msg_changed = '已删除行尾句号与多余空白',
    msg_unchanged = '没有找到需要处理的内容',
  }))
end

---@class vv-utils.format.Opts
---@field commands? boolean  是否注册 :VVAddSpaces / :VVCleanTrailing user command（默认 true）

--- 启用 format 模块的副作用：注册 user command（keymap 由用户自行在配置层绑定）
---@param opts? vv-utils.format.Opts
function M.setup(opts)
  opts = opts or {}
  if opts.commands == false then return end

  -- ctx.range > 0 → 显式带 range（如 :5,10VVAddSpaces 或 visual `:` 自动 prepend '<,'>）
  -- ctx.range == 0 → 让 add_spaces() 自己嗅探 visual 选区或退回全文
  vim.api.nvim_create_user_command('VVAddSpaces', function(ctx)
    M.add_spaces(ctx.range > 0 and { range = { ctx.line1, ctx.line2 } } or nil)
  end, { range = true, desc = 'vv-utils.format: 中英文之间智能加空格' })

  vim.api.nvim_create_user_command('VVCleanTrailing', function(ctx)
    M.clean_trailing(ctx.range > 0 and { range = { ctx.line1, ctx.line2 } } or nil)
  end, { range = true, desc = 'vv-utils.format: 清理行尾句号与多余空白' })
end

return M
