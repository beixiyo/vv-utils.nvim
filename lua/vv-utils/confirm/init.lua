-- 通用确认浮窗 facade：编排内容、窗口与二元确认生命周期

require('vv-utils.confirm.types')

local Keymaps = require('vv-utils.confirm.keymaps')
local Config = require('vv-utils.confirm.config')
local Render = require('vv-utils.confirm.render')
local Window = require('vv-utils.confirm.window')

local M = {}

---@param opts? VVConfirmConfig
function M.setup(opts)
  Config.setup(opts)
end

---@return VVConfirmConfig
function M.get_config()
  return Config.get()
end

local function invoke(callback, kind)
  if not callback then
    return
  end

  local ok, err = pcall(callback)
  if not ok then
    vim.notify('vv-utils.confirm: ' .. kind .. ' callback failed: ' .. tostring(err), vim.log.levels.WARN)
  end
end

---@param opts VVConfirmOptions
---@return VVConfirmHandle
function M.open(opts)
  local config = Config.resolve(opts.actions)
  local resolved_opts = vim.tbl_extend('force', {}, opts, { actions = config.actions })
  local content = Render.build(resolved_opts)
  local buffer, window = Window.open(content, resolved_opts)
  local closed = false

  local function close()
    if closed then
      return
    end

    closed = true
    if vim.api.nvim_win_is_valid(window) then
      vim.api.nvim_win_close(window, true)
    end
  end

  local function confirm()
    close()
    invoke(opts.on_confirm, 'confirm')
  end

  local function cancel()
    close()
    invoke(opts.on_cancel, 'cancel')
  end

  Keymaps.attach(buffer, config.actions, confirm, cancel)

  return { close = close }
end

return M
