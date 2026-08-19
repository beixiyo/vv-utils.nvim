-- TreePanel 固定多行工具栏
--
-- 使用与正文同列的独立水平窗口承载快捷键提示，因此提示可按宽度完整换行，
-- 同时不覆盖正文，也不参与正文滚动

local Keys = require('vv-utils.keys')
local UIWindow = require('vv-utils.ui_window')

local M = {}

local function panel_normal_hl(panel)
  local value = panel.win and vim.api.nvim_win_is_valid(panel.win)
      and vim.wo[panel.win].winhighlight or ''
  for mapping in value:gmatch('[^,]+') do
    local source, target = mapping:match('^([^:]+):(.+)$')
    if source == 'Normal' then return target end
  end
  return 'Normal'
end

local function sync_background(panel)
  if not (panel.toolbar_win and vim.api.nvim_win_is_valid(panel.toolbar_win)) then return end
  local normal_hl = panel_normal_hl(panel)
  vim.wo[panel.toolbar_win].winhighlight = table.concat({
    'Normal:' .. normal_hl,
    'EndOfBuffer:' .. normal_hl,
    'StatusLine:' .. normal_hl,
    'StatusLineNC:' .. normal_hl,
    'WinSeparator:' .. normal_hl,
  }, ',')
end

local function display_width(chunks)
  local total = 0
  for _, chunk in ipairs(chunks) do total = total + vim.fn.strdisplaywidth(chunk[1]) end
  return total
end

local function hint_chunks(item, opts)
  return {
    { item.label .. ' ', item.label_hl or opts.label_hl or 'Comment' },
    { Keys.display(item.key), item.key_hl or opts.key_hl or 'Special' },
  }
end

---@param items VVTreePanelToolbarItem[]
---@param width integer
---@param opts VVTreePanelToolbarOptions
---@return VVTreePanelChunk[][]
function M.wrap(items, width, opts)
  local padding = math.max(0, opts.padding or 1)
  local separator = opts.separator or '  '
  local content_width = math.max(1, width - padding * 2)
  local rows = {}
  local current = {}
  local current_width = 0

  for _, item in ipairs(items or {}) do
    local chunks = hint_chunks(item, opts)
    local item_width = display_width(chunks)
    local gap = #current > 0 and vim.fn.strdisplaywidth(separator) or 0

    if #current > 0 and current_width + gap + item_width > content_width then
      table.insert(current, 1, { string.rep(' ', padding), opts.label_hl or 'Comment' })
      rows[#rows + 1] = current
      current = {}
      current_width = 0
      gap = 0
    end
    if gap > 0 then current[#current + 1] = { separator, opts.label_hl or 'Comment' } end
    vim.list_extend(current, chunks)
    current_width = current_width + gap + item_width
  end

  if #current > 0 then
    table.insert(current, 1, { string.rep(' ', padding), opts.label_hl or 'Comment' })
    rows[#rows + 1] = current
  end
  return #rows > 0 and rows or { { { '' } } }
end

local function toolbar_items(panel)
  local source = panel.opts.toolbar and panel.opts.toolbar.items
  if type(source) == 'function' then return source({ panel = panel }) or {} end
  return source or {}
end

---@param panel VVTreePanel
function M.render(panel)
  if not (panel.toolbar_win and vim.api.nvim_win_is_valid(panel.toolbar_win)
      and panel.toolbar_buf and vim.api.nvim_buf_is_valid(panel.toolbar_buf))
  then return end

  sync_background(panel)
  local rows = M.wrap(toolbar_items(panel), vim.api.nvim_win_get_width(panel.toolbar_win), panel.opts.toolbar)
  vim.bo[panel.toolbar_buf].modifiable = true

  vim.api.nvim_buf_set_lines(panel.toolbar_buf, 0, -1, false, vim.tbl_map(function(chunks)
    local parts = {}
    for _, chunk in ipairs(chunks) do parts[#parts + 1] = chunk[1] end
    return table.concat(parts)
  end, rows))
  vim.api.nvim_buf_clear_namespace(panel.toolbar_buf, panel.toolbar_ns, 0, -1)

  for row, chunks in ipairs(rows) do
    local col = 0
    for _, chunk in ipairs(chunks) do
      if chunk[2] and chunk[1] ~= '' then
        vim.api.nvim_buf_set_extmark(panel.toolbar_buf, panel.toolbar_ns, row - 1, col, {
          end_col = col + #chunk[1],
          hl_group = chunk[2],
        })
      end
      col = col + #chunk[1]
    end
  end

  vim.bo[panel.toolbar_buf].modifiable = false
  if vim.api.nvim_win_get_height(panel.toolbar_win) ~= #rows then
    vim.api.nvim_win_set_height(panel.toolbar_win, #rows)
  end
end

---@param panel VVTreePanel
function M.open(panel)
  if not panel.opts.toolbar then return end
  local panel_win = panel.win

  vim.api.nvim_set_current_win(panel_win)
  vim.cmd('aboveleft 1new')

  panel.toolbar_win = vim.api.nvim_get_current_win()
  panel.toolbar_buf = vim.api.nvim_get_current_buf()
  panel.toolbar_ns = vim.api.nvim_create_namespace('vv-utils-tree-panel-toolbar-' .. panel.opts.id)
  panel.toolbar_group = vim.api.nvim_create_augroup(
    'VVTreePanelToolbar' .. panel.toolbar_buf,
    { clear = true }
  )

  vim.bo[panel.toolbar_buf].buftype = 'nofile'
  vim.bo[panel.toolbar_buf].bufhidden = 'wipe'
  vim.bo[panel.toolbar_buf].swapfile = false
  vim.bo[panel.toolbar_buf].modifiable = false
  vim.bo[panel.toolbar_buf].filetype = panel.opts.toolbar.filetype or 'vv-tree-panel-toolbar'
  vim.api.nvim_buf_set_name(panel.toolbar_buf, ('vv-tree-panel-toolbar://%s'):format(panel.opts.id))

  UIWindow.hide_chrome(panel.toolbar_win, {
    winfixheight = true,
    winfixwidth = true,
    cursorline = false,
  })

  vim.wo[panel.toolbar_win].winbar = ''
  vim.wo[panel.toolbar_win].statusline = '%#Normal# '
  sync_background(panel)
  vim.wo[panel.toolbar_win].fillchars = 'horiz: ,horizup: ,horizdown: '

  vim.api.nvim_create_autocmd('BufEnter', {
    group = panel.toolbar_group,
    buffer = panel.toolbar_buf,
    callback = function()
      vim.schedule(function()
        if panel:is_open() then vim.api.nvim_set_current_win(panel.win) end
      end)
    end,
  })

  M.render(panel)
  vim.api.nvim_set_current_win(panel_win)
end

---@param panel VVTreePanel
function M.close(panel)
  local win = panel.toolbar_win
  local buf = panel.toolbar_buf
  local group = panel.toolbar_group
  panel.toolbar_win = nil
  panel.toolbar_buf = nil
  panel.toolbar_ns = nil
  panel.toolbar_group = nil
  if group then pcall(vim.api.nvim_del_augroup_by_id, group) end
  if win and vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
  if buf and vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
end

return M
