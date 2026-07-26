-- 文件位置预览器：侧栏移动时在来源窗口预览，关闭时恢复，跳转时保留

local M = {}

---@class VVTreePanelFilePreview
---@field source_win integer
---@field original_buf integer
---@field original_view table
---@field committed boolean
local Preview = {}
Preview.__index = Preview

---@param source_win integer
---@return VVTreePanelFilePreview
function M.new(source_win)
  return setmetatable({
    source_win = source_win,
    original_buf = vim.api.nvim_win_get_buf(source_win),
    original_view = vim.api.nvim_win_call(source_win, vim.fn.winsaveview),
    committed = false,
  }, Preview)
end

---@param location? { file: string, row: integer, col?: integer }
function Preview:show(location)
  if not location or not vim.api.nvim_win_is_valid(self.source_win) then return end

  local existed = vim.fn.bufnr(location.file) >= 0
  local buf = vim.fn.bufadd(location.file)
  vim.fn.bufload(buf)
  if not existed then vim.bo[buf].buflisted = false end
  vim.api.nvim_win_set_buf(self.source_win, buf)

  local row = math.max(1, math.min(location.row or 1, vim.api.nvim_buf_line_count(buf)))
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ''
  local col = math.max(0, math.min(location.col or 0, #line))
  vim.api.nvim_win_set_cursor(self.source_win, { row, col })
  vim.api.nvim_win_call(self.source_win, function() vim.cmd('normal! zz') end)
end

---@param location? { file: string, row: integer, col?: integer }
function Preview:jump(location)
  if not location then return end

  self:show(location)
  self.committed = true
  if vim.api.nvim_win_is_valid(self.source_win) then vim.api.nvim_set_current_win(self.source_win) end
end

function Preview:restore()
  if self.committed or not vim.api.nvim_win_is_valid(self.source_win) then return end
  if not vim.api.nvim_buf_is_valid(self.original_buf) then return end

  vim.api.nvim_win_set_buf(self.source_win, self.original_buf)
  vim.api.nvim_win_call(self.source_win, function() vim.fn.winrestview(self.original_view) end)
end

return M
