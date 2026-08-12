-- 确认框窗口：创建 scratch buffer、写入渲染结果并配置浮窗

local M = {}
local namespace = vim.api.nvim_create_namespace('vv-utils-confirm')

---@param content { lines:string[], marks:table[], width:integer, height:integer, footer_row?:integer }
---@param opts VVConfirmOptions
---@return integer buffer, integer window
function M.open(content, opts)
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, content.lines)
  vim.bo[buffer].bufhidden = 'wipe'
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].filetype = opts.filetype or 'vv-confirm'

  for _, mark in ipairs(content.marks) do
    vim.api.nvim_buf_set_extmark(buffer, namespace, mark.row, mark.col, {
      end_col = mark.col + mark.length,
      hl_group = mark.hl,
    })
  end

  local window_opts = opts.window or {}
  local window = vim.api.nvim_open_win(buffer, true, {
    relative = 'editor',
    style = 'minimal',
    border = window_opts.border or 'rounded',
    title = { { ' ' .. opts.title .. ' ', 'Title' } },
    title_pos = window_opts.title_pos or 'center',
    row = math.floor((vim.o.lines - content.height) / 2),
    col = math.floor((vim.o.columns - content.width) / 2),
    width = content.width,
    height = content.height,
    zindex = window_opts.zindex,
  })

  vim.wo[window].wrap = true
  vim.wo[window].linebreak = true
  vim.wo[window].cursorline = false
  vim.wo[window].scrolloff = 0

  -- 正文超过视口时先定位到最后一行操作区，同时允许用户向上滚动查看详情
  if content.footer_row then
    pcall(vim.api.nvim_win_set_cursor, window, { content.footer_row + 1, 0 })
  end

  return buffer, window
end

return M
