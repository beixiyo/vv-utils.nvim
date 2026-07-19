-- 文本变换的 buffer 适配层
--
-- 负责选区解析、可修改性检查、buffer 写回与用户通知

local M = {}

---@return integer?, integer?
local function visual_line_range()
  local mode = vim.fn.mode()
  if not (mode == 'v' or mode == 'V' or mode == '\22') then return nil end

  vim.cmd([[execute "normal! \<Esc>"]])
  local start_row = vim.api.nvim_buf_get_mark(0, '<')[1]
  local end_row = vim.api.nvim_buf_get_mark(0, '>')[1]
  if start_row > end_row then start_row, end_row = end_row, start_row end
  return start_row, end_row
end

---把文本变换应用到当前 buffer
---@param transform fun(text: string): string
---@param opts? { range?: integer[], msg_changed?: string, msg_unchanged?: string, silent?: boolean }
---@return boolean changed
function M.apply(transform, opts)
  opts = opts or {}

  local from_row, to_row
  if opts.range then
    from_row, to_row = opts.range[1] - 1, opts.range[2]
  else
    local start_row, end_row = visual_line_range()
    if start_row then
      from_row, to_row = start_row - 1, end_row
    else
      from_row, to_row = 0, -1
    end
  end

  local lines = vim.api.nvim_buf_get_lines(0, from_row, to_row, false)
  -- vim.fn.substitute() 会把含 NUL 的 Lua string 当成 VimL Blob（E976）
  for index, line in ipairs(lines) do
    lines[index] = line:gsub('%z', '')
  end
  local original = table.concat(lines, '\n')
  local processed = transform(original)

  if processed == original then
    if not opts.silent then
      vim.notify(opts.msg_unchanged or 'Nothing to process', vim.log.levels.INFO, { title = 'vv-utils.format' })
    end
    return false
  end

  if not vim.bo.modifiable then
    if not opts.silent then
      vim.notify('buffer 不可修改', vim.log.levels.WARN, { title = 'vv-utils.format' })
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

return M
