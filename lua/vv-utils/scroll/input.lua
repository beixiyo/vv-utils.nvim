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
local saved_mousescroll
local owned_mousescroll
local saved_keymaps = {}

local function mapping_key(mode, lhs)
  return mode .. '\0' .. lhs
end

local function save_mapping(mode, lhs)
  local key = mapping_key(mode, lhs)
  if saved_keymaps[key] ~= nil then return end
  local mapping = vim.fn.maparg(lhs, mode, false, true)
  saved_keymaps[key] = type(mapping) == 'table' and next(mapping) and mapping or false
end

local function restore_mapping(mode, lhs)
  local mapping = saved_keymaps[mapping_key(mode, lhs)]
  if mapping == nil then return end

  local current = vim.fn.maparg(lhs, mode, false, true)
  if type(current) == 'table' and next(current) then
    local desc = current.desc and tostring(current.desc) or ''
    if not desc:match('^vv%-scroll:') then return end
  end

  pcall(vim.keymap.del, mode, lhs)
  if mapping then vim.fn.mapset(mode, false, mapping) end
end

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
        restore_mapping(mode, key.lhs)
      end
    end
    return
  end

  for _, key in ipairs(mouse_keys) do
    for _, mode in ipairs(mouse_modes) do save_mapping(mode, key.lhs) end
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
  if saved_mousescroll == nil then saved_mousescroll = vim.o.mousescroll end
  if config.mouse_step and config.mouse_step > 0 then
    vim.opt.mousescroll = ('ver:%d,hor:6'):format(config.mouse_step)
    owned_mousescroll = vim.o.mousescroll
  end

  sync_mouse_keymaps()
  install_autocmds()

  if scroll_keymaps_installed then return end
  scroll_keymaps_installed = true

  for _, mode in ipairs({ 'n', 'x' }) do
    save_mapping(mode, '<C-e>')
    save_mapping(mode, '<C-y>')
  end

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

function M.uninstall()
  pcall(vim.api.nvim_del_augroup_by_name, 'VVUtilsScroll')

  for _, mode in ipairs({ 'n', 'x' }) do
    restore_mapping(mode, '<C-e>')
    restore_mapping(mode, '<C-y>')
  end
  for _, key in ipairs(mouse_keys) do
    for _, mode in ipairs(mouse_modes) do
      restore_mapping(mode, key.lhs)
    end
  end

  if saved_mousescroll ~= nil and vim.o.mousescroll == owned_mousescroll then
    vim.o.mousescroll = saved_mousescroll
  end
  saved_mousescroll = nil
  owned_mousescroll = nil
  saved_keymaps = {}
  scroll_keymaps_installed = false
end

return M
