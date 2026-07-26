---@diagnostic disable: inject-field
-- Tree panel 的窗口、timer 与 autocmd 生命周期

local Preview = require('vv-utils.tree_panel.preview')
local Timer = require('vv-utils.timer')
local UIWindow = require('vv-utils.ui_window')

local M = {}

---@param panel VVTreePanel
local function release(panel)
  if panel.cancel_preview then panel.cancel_preview() end
  if panel.cancel_width_save then panel.cancel_width_save() end
  if panel.lifecycle_group then pcall(vim.api.nvim_del_augroup_by_id, panel.lifecycle_group) end

  panel.preview_cursor = nil
  panel.cancel_preview = nil
  panel.save_width_debounced = nil
  panel.cancel_width_save = nil
  panel.lifecycle_group = nil
  panel.win = nil
  panel.buf = nil
  panel.file_preview = nil
end

---@param name string
---@param callback? fun(ctx: VVTreePanelRenderContext)
---@param panel VVTreePanel
local function run_hook(name, callback, panel)
  if not callback then return end
  local ok, err = xpcall(function() callback({ panel = panel }) end, debug.traceback)
  if not ok then vim.notify(('tree panel %s failed:\n%s'):format(name, err), vim.log.levels.ERROR) end
end

---@param panel VVTreePanel
local function cleanup(panel)
  pcall(function() panel:_save_width() end)
  run_hook('close_preview', panel.opts.close_preview, panel)
  run_hook('on_close', panel.opts.on_close, panel)
  if not panel.opts.preview and panel.file_preview then pcall(function() panel.file_preview:restore() end) end
  release(panel)
end

---@param panel VVTreePanel
function M.open(panel)
  panel.source_win = vim.api.nvim_get_current_win()
  panel.file_preview = Preview.new(panel.source_win)
  panel.preview_cursor, panel.cancel_preview = Timer.debounce(function()
    panel:_preview_cursor()
  end, panel.opts.preview_debounce_ms or 80)
  if panel.opts.state then
    panel.save_width_debounced, panel.cancel_width_save = Timer.debounce(function()
      panel:_save_width()
    end, panel.opts.width_save_debounce_ms or 120)
  end

  panel.buf = vim.api.nvim_create_buf(false, true)
---@diagnostic disable-next-line: inject-field
  panel.ns = vim.api.nvim_create_namespace('vv-utils-tree-panel-' .. panel.opts.id)

  local position = panel.opts.position == 'left' and 'topleft' or 'botright'
  local initial_width = panel:_initial_width()
  vim.cmd(('%s vsplit'):format(position))
  panel.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(panel.win, initial_width)
  panel.current_width = vim.api.nvim_win_get_width(panel.win)
  panel.saved_width = initial_width
  vim.api.nvim_win_set_buf(panel.win, panel.buf)

  vim.bo[panel.buf].buftype = 'nofile'
  vim.bo[panel.buf].bufhidden = 'wipe'
  vim.bo[panel.buf].swapfile = false
  vim.bo[panel.buf].filetype = panel.opts.filetype or 'vv-tree-panel'
  vim.bo[panel.buf].modifiable = false
  vim.api.nvim_buf_set_name(panel.buf, ('vv-tree-panel://%s'):format(panel.opts.id))

  UIWindow.hide_chrome(panel.win, {
    cursorline = true,
    winfixwidth = true,
  })
  vim.wo[panel.win].winhighlight = 'Normal:Normal,CursorLine:Visual'

  if panel.opts.on_attach then panel.opts.on_attach(panel, panel.buf) end
  panel:render()

  panel.lifecycle_group = vim.api.nvim_create_augroup(
    ('VVTreePanelLifecycle%d'):format(panel.buf),
    { clear = true }
  )
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = panel.lifecycle_group,
    buffer = panel.buf,
    callback = function() panel.preview_cursor() end,
  })
  vim.api.nvim_create_autocmd('WinResized', {
    group = panel.lifecycle_group,
    callback = function()
      panel:_remember_width()
      if panel.save_width_debounced then panel.save_width_debounced() end
    end,
  })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = panel.lifecycle_group,
    callback = function() panel:_save_width() end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = panel.lifecycle_group,
    buffer = panel.buf,
    once = true,
    callback = function() cleanup(panel) end,
  })

  if panel.preview_cursor then panel.preview_cursor() end
end

---@param panel VVTreePanel
function M.rollback(panel)
  local win = panel.win
  local buf = panel.buf
  if win and vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
  if buf and vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
  if panel.file_preview then pcall(function() panel.file_preview:restore() end) end
  release(panel)
end

return M
