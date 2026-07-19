-- vv-utils.scroll.viewport — 目标窗口的视口读写原语

local M = {}

---@param win_id integer
---@param n integer
---@param key string
---@return boolean
function M.scroll_lines(win_id, n, key)
  return pcall(vim.api.nvim_win_call, win_id, function()
    vim.cmd(('normal! %d%s'):format(n, key))
  end)
end

---@param win_id integer
---@param lines integer
function M.scroll_instant(win_id, lines)
  local key = lines > 0 and '\5' or '\25'
  M.scroll_lines(win_id, math.abs(lines), key)
end

---@param win_id integer
---@return table
function M.capture_view(win_id)
  return vim.api.nvim_win_call(win_id, function()
    return vim.fn.winsaveview()
  end)
end

---@param before table
---@param after table
---@return boolean
local function view_moved(before, after)
  return before.topline ~= after.topline
    or before.topfill ~= after.topfill
    or before.skipcol ~= after.skipcol
end

---@param win_id integer
---@param key string
---@return boolean
function M.scroll_line(win_id, key)
  local before = M.capture_view(win_id)
  if not M.scroll_lines(win_id, 1, key) then return false end

  return view_moved(before, M.capture_view(win_id))
end

---@param win_id? integer
---@return table?
function M.capture_state(win_id)
  if not win_id or not vim.api.nvim_win_is_valid(win_id) then return nil end

  local ok, state = pcall(vim.api.nvim_win_call, win_id, function()
    return {
      buf_id = vim.api.nvim_get_current_buf(),
      win_id = win_id,
      view = vim.fn.winsaveview(),
      cursor = { line = vim.fn.line('.'), virtcol = vim.fn.virtcol('.') },
      scrolloff = vim.wo.scrolloff,
      virtualedit = vim.wo.virtualedit,
    }
  end)

  return ok and state or nil
end

---@return integer
function M.mouse_target_win()
  local ok, pos = pcall(vim.fn.getmousepos)
  if ok and pos and pos.winid and pos.winid ~= 0
      and vim.api.nvim_win_is_valid(pos.winid) then
    return pos.winid
  end

  return vim.api.nvim_get_current_win()
end

return M
