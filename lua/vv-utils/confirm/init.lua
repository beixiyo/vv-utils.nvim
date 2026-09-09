-- 确认框适配器：把二元确认语义交给通用 vv-utils.modal

require('vv-utils.confirm.types')

local Config = require('vv-utils.confirm.config')
local Modal = require('vv-utils.modal')

local M = {}

---@param opts? VVConfirmConfig
function M.setup(opts)
  Config.setup(opts)
end

---@return VVConfirmConfig
function M.get_config()
  return Config.get()
end

local function split_lines(value)
  local result = vim.split(tostring(value or ''), '\n', { plain = true, trimempty = false })
  for index, line in ipairs(result) do result[index] = line:gsub('\r$', '') end
  return #result > 0 and result or { '' }
end

local function message_rows(message)
  if message == nil then return {} end
  local items
  if type(message) == 'table' and message.text then
    items = { message }
  elseif type(message) == 'table' then
    items = message
  else
    items = { message }
  end

  local rows = {}
  for _, item in ipairs(items) do
    if type(item) == 'table' then
      for index, text in ipairs(split_lines(item.text)) do
        rows[#rows + 1] = {
          text = text,
          hl = item.hl or 'Normal',
          icon = index == 1 and item.icon or nil,
          icon_hl = item.icon_hl,
        }
      end
    else
      for _, text in ipairs(split_lines(item)) do rows[#rows + 1] = { text = text, hl = 'Normal' } end
    end
  end
  return rows
end

local function body_rows(opts)
  local rows = message_rows(opts.message)
  local details = opts.details or {}
  if #details > 0 and #rows > 0 and rows[#rows].text ~= '' then rows[#rows + 1] = { text = '' } end
  for _, detail in ipairs(details) do
    if detail.separator_before then rows[#rows + 1] = { text = '' } end
    for _, line in ipairs(split_lines(detail.label)) do rows[#rows + 1] = { text = line, hl = 'Comment' } end
    for _, line in ipairs(split_lines(detail.value)) do
      rows[#rows + 1] = { text = '  ' .. line, hl = detail.hl or 'Directory' }
    end
  end
  return rows
end

local confirm_highlights = { info = 'DiagnosticOk', warn = 'DiagnosticWarn', danger = 'DiagnosticError' }

---@param opts VVConfirmOptions
---@return VVConfirmHandle
function M.open(opts)
  local config = Config.resolve(opts.actions)
  local severity = opts.severity or 'info'
  local confirm_hl = opts.confirm_hl or confirm_highlights[severity] or 'DiagnosticOk'
  local actions = {}
  if #config.actions.confirm.keys > 0 then
    actions[1] = {
      id = 'confirm',
      label = tostring(opts.confirm_label or 'Confirm'),
      icon = tostring(opts.confirm_icon or '󰄬'),
      keys = config.actions.confirm.keys,
      hint = config.actions.confirm.hint,
      hl = confirm_hl,
    }
  end
  local modal_opts = {
    title = opts.title,
    body = body_rows(opts),
    actions = actions,
    cancel = {
      label = tostring(opts.cancel_label or 'Cancel'),
      icon = tostring(opts.cancel_icon or '󰜺'),
      keys = config.actions.cancel.keys,
      hint = config.actions.cancel.hint,
      hl = 'Comment',
    },
    window = opts.window,
    filetype = opts.filetype or 'vv-confirm',
    on_select = function(id)
      if id == 'confirm' and opts.on_confirm then opts.on_confirm() end
    end,
    on_cancel = opts.on_cancel,
  }
  return Modal.open(modal_opts)
end

return M
