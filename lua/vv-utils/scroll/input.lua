-- vv-utils.scroll.input — 鼠标、键盘映射与视口事件接入

local animation = require('vv-utils.scroll.animation')
local state = require('vv-utils.scroll.state')
local viewport = require('vv-utils.scroll.viewport')

local M = {}

local mouse_modes = { 'n', 'x', 'i' }
local mouse_keys = {
  { lhs = '<ScrollWheelDown>', dir = 'down', desc = 'vv-scroll: mouse scroll down' },
  { lhs = '<ScrollWheelUp>', dir = 'up', desc = 'vv-scroll: mouse scroll up' },
}

local scroll_keymaps_installed = false

---按鼠标滚轮方向滚动鼠标所在窗口
---@param direction 'up'|'down'
---@param win_id? integer 显式目标窗口；不传时使用鼠标所在窗口
---@return boolean handled 是否已接管滚动
function M.mouse(direction, win_id)
  local config = state.config()
  local step = config.mouse_step or state.defaults.mouse_step
  if step <= 0 then return false end

  local target_win = win_id or viewport.mouse_target_win()
  local lines = direction == 'up' and -step or step

  if config.mouse == 'smooth' and not vim.g.neovide and config.enabled then
    animation.window(target_win, lines)
  else
    viewport.scroll_instant(target_win, lines)
    animation.track_state(target_win)
  end

  return true
end

local function del_mouse_keymap(mode, lhs)
  local map = vim.fn.maparg(lhs, mode, false, true)
  if map and map.desc and tostring(map.desc):match('^vv%-scroll: mouse') then
    pcall(vim.keymap.del, mode, lhs)
  end
end

local function sync_mouse_keymaps()
  if state.config().mouse ~= 'smooth' then
    for _, key in ipairs(mouse_keys) do
      for _, mode in ipairs(mouse_modes) do
        del_mouse_keymap(mode, key.lhs)
      end
    end
    return
  end

  for _, key in ipairs(mouse_keys) do
    vim.keymap.set(mouse_modes, key.lhs, function()
      M.mouse(key.dir)
    end, { desc = key.desc })
  end
end

local function install_autocmds()
  local augroup = vim.api.nvim_create_augroup('VVUtilsScroll', { clear = true })

  vim.api.nvim_create_autocmd('WinScrolled', {
    group = augroup,
    callback = animation.on_win_scrolled,
    desc = 'vv-scroll: animate viewport jumps',
  })

  vim.api.nvim_create_autocmd({ 'BufEnter', 'WinEnter' }, {
    group = augroup,
    callback = function()
      vim.schedule(function()
        if vim.api.nvim_get_current_win() then
          animation.track_state(vim.api.nvim_get_current_win())
        end
      end)
    end,
    desc = 'vv-scroll: track viewport state',
  })

  vim.api.nvim_create_autocmd('CursorMoved', {
    group = augroup,
    callback = function()
      local win_id = vim.api.nvim_get_current_win()
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(win_id) then
          animation.track_state_partial(win_id)
        end
      end)
    end,
    desc = 'vv-scroll: track cursor for viewport animation',
  })

  animation.track_state(vim.api.nvim_get_current_win())
end

---安装全局滚动键映射（键盘 C-e/C-y）与视口事件
function M.install()
  local config = state.config()
  if config.mouse_step and config.mouse_step > 0 then
    vim.opt.mousescroll = ('ver:%d,hor:6'):format(config.mouse_step)
  end

  sync_mouse_keymaps()
  install_autocmds()

  if scroll_keymaps_installed then return end
  scroll_keymaps_installed = true

  local function count_lines()
    return vim.v.count > 0 and vim.v.count or state.config().step
  end

  vim.keymap.set({ 'n', 'x' }, '<C-e>', function()
    animation.window(vim.api.nvim_get_current_win(), count_lines())
  end, { desc = 'vv-scroll: scroll down' })

  vim.keymap.set({ 'n', 'x' }, '<C-y>', function()
    animation.window(vim.api.nvim_get_current_win(), -count_lines())
  end, { desc = 'vv-scroll: scroll up' })
end

return M
