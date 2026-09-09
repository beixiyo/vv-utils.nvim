-- 通用多动作 Modal：唯一负责声明式正文、动作映射与浮窗生命周期

require('vv-utils.modal.types')

local UIWindow = require('vv-utils.ui_window')
local Render = require('vv-utils.modal.render')

local M = {}
local namespace = vim.api.nvim_create_namespace('vv-utils-modal')

local function normalize_keys(value, label, allow_empty)
  if type(value) == 'string' then value = { value } end
  if type(value) ~= 'table' or (#value == 0 and not allow_empty) then
    error(('vv-utils.modal: %s.keys must be a non-empty string or list'):format(label))
  end

  local result, seen = {}, {}
  for _, key in ipairs(value) do
    if type(key) ~= 'string' or key == '' then
      error(('vv-utils.modal: %s.keys must contain non-empty strings'):format(label))
    end
    local encoded = vim.keycode(key)
    if not seen[encoded] then
      seen[encoded] = true
      result[#result + 1] = key
    end
  end

  return result
end

local function normalize(opts)
  assert(type(opts) == 'table', 'vv-utils.modal.open requires options')
  assert(type(opts.title) == 'string', 'vv-utils.modal: title must be a string')
  assert(type(opts.actions) == 'table', 'vv-utils.modal: actions must be a list')
  assert(opts.body == nil or opts.render == nil, 'vv-utils.modal: body and render are mutually exclusive')
  assert(opts.render == nil or type(opts.render) == 'function',
    'vv-utils.modal: render must be a function')
  assert(opts.on_select == nil or type(opts.on_select) == 'function',
    'vv-utils.modal: on_select must be a function')
  assert(opts.on_cancel == nil or type(opts.on_cancel) == 'function',
    'vv-utils.modal: on_cancel must be a function')

  local actions, bindings, ids = {}, {}, {}
  for index, action in ipairs(opts.actions) do
    assert(type(action) == 'table', ('vv-utils.modal: actions[%d] must be a table'):format(index))
    assert(type(action.id) == 'string' and action.id ~= '',
      ('vv-utils.modal: actions[%d].id must be non-empty'):format(index))
    assert(type(action.label) == 'string' and action.label ~= '',
      ('vv-utils.modal: actions[%d].label must be non-empty'):format(index))
    assert(not ids[action.id], ('vv-utils.modal: duplicate action id %s'):format(action.id))

    ids[action.id] = true
    local item = vim.tbl_extend('force', {}, action)
    item.keys = normalize_keys(action.keys, ('actions[%d]'):format(index))

    assert(item.hint == nil or item.hint == false or type(item.hint) == 'string',
      ('vv-utils.modal: actions[%d].hint must be a string or false'):format(index))
    assert(item.icon == nil or type(item.icon) == 'string',
      ('vv-utils.modal: actions[%d].icon must be a string'):format(index))

    actions[#actions + 1] = item
    for _, key in ipairs(item.keys) do
      local encoded = vim.keycode(key)
      if bindings[encoded] then
        error(('vv-utils.modal: key %s is assigned to both %s and %s')
          :format(key, bindings[encoded], action.id))
      end
      bindings[encoded] = action.id
    end
  end

  local cancel = vim.tbl_extend('force', {
    label = 'Cancel',
    keys = { 'q', '<Esc>' },
    hl = 'Comment',
  }, opts.cancel or {})
  cancel.keys = normalize_keys(cancel.keys, 'cancel', true)
  assert(type(cancel.label) == 'string' and cancel.label ~= '',
    'vv-utils.modal: cancel.label must be non-empty')
  assert(cancel.hint == nil or cancel.hint == false or type(cancel.hint) == 'string',
    'vv-utils.modal: cancel.hint must be a string or false')
  assert(cancel.icon == nil or type(cancel.icon) == 'string',
    'vv-utils.modal: cancel.icon must be a string')

  for _, key in ipairs(cancel.keys) do
    local encoded = vim.keycode(key)
    if bindings[encoded] then
      error(('vv-utils.modal: key %s is assigned to both %s and cancel')
        :format(key, bindings[encoded]))
    end
    bindings[encoded] = 'cancel'
  end

  local resolved = vim.tbl_extend('force', {}, opts, { actions = actions, cancel = cancel })
  return resolved, bindings
end

local function invoke(callback, kind, id)
  if not callback then return end
  local ok, err = pcall(callback, id)

  if not ok then
    vim.notify(('vv-utils.modal: %s callback failed: %s'):format(kind, tostring(err)), vim.log.levels.WARN)
  end
end

---@param opts VVModalOptions
---@return VVModalHandle
function M.open(opts)
  local resolved = normalize(opts)
  local body = resolved.body

  if resolved.render then body = resolved.render(resolved.context or {}) end
  body = body or {}
  local content = Render.build(resolved, body)

  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, content.lines)
  vim.bo[buffer].bufhidden = 'wipe'
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].filetype = resolved.filetype or 'vv-modal'

  for _, mark in ipairs(content.marks) do
    if mark.virt_text then
      vim.api.nvim_buf_set_extmark(buffer, namespace, mark.row, mark.col, {
        virt_text = mark.virt_text,
        virt_text_pos = mark.virt_text_pos,
      })
    else
      vim.api.nvim_buf_set_extmark(buffer, namespace, mark.row, mark.col, {
        end_col = mark.col + mark.length,
        hl_group = mark.hl,
      })
    end
  end

  local window_opts = resolved.window or {}
  local float = UIWindow.centered_config({
    width = content.width,
    height = content.height,
    margin = window_opts.margin,
    border = window_opts.border,
    title = { { ' ' .. resolved.title .. ' ', 'Title' } },
    title_pos = window_opts.title_pos,
  })

  if window_opts.zindex then float.zindex = window_opts.zindex end
  local window = vim.api.nvim_open_win(buffer, true, float)

  UIWindow.hide_chrome(window, window_opts.chrome)
  vim.wo[window].wrap = true
  vim.wo[window].linebreak = true
  vim.wo[window].cursorline = false
  vim.wo[window].scrolloff = 0
  if content.footer_row then pcall(vim.api.nvim_win_set_cursor, window, { content.footer_row + 1, 0 }) end

  local closed = false
  local function external_close()
    if closed then return end
    closed = true
    invoke(resolved.on_cancel, 'cancel')
  end

  local function close()
    if closed then return end
    closed = true
    if vim.api.nvim_win_is_valid(window) then vim.api.nvim_win_close(window, true) end
  end
  local function select_action(id)
    if closed then return end
    close()
    invoke(resolved.on_select, 'select', id)
  end
  local function cancel()
    if closed then return end
    close()
    invoke(resolved.on_cancel, 'cancel')
  end

  for _, action in ipairs(resolved.actions) do
    for _, key in ipairs(action.keys) do
      vim.keymap.set('n', key, function() select_action(action.id) end, {
        buffer = buffer,
        nowait = true,
        silent = true,
      })
    end
  end

  for _, key in ipairs(resolved.cancel.keys) do
    vim.keymap.set('n', key, cancel, { buffer = buffer, nowait = true, silent = true })
  end

  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buffer,
    once = true,
    callback = external_close,
  })
  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(window),
    once = true,
    callback = external_close,
  })

  return {
    close = close,
    is_open = function() return not closed and vim.api.nvim_win_is_valid(window) end,
  }
end

return M
