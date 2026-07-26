-- Global side-effect lifecycle integration
-- Run: nvim --headless -u NONE -l tests/test_global_lifecycle.lua

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
vim.opt.runtimepath:prepend(root)

local function snapshot_mapping(mode, lhs)
  local mapping = vim.fn.maparg(lhs, mode, false, true)
  return type(mapping) == 'table' and next(mapping) and mapping or nil
end

local function restore_mapping(mode, lhs, mapping)
  pcall(vim.keymap.del, mode, lhs)
  if mapping then vim.fn.mapset(mode, false, mapping) end
end

local Drop = require('vv-utils.drop')
local Dispatcher = require('vv-utils.drop.dispatcher')
local original_paste = vim.paste

Drop.setup({ kitty_dnd = false })
assert(vim.paste ~= original_paste, 'drop setup should install its paste handler')
Drop.teardown()
assert(vim.paste == original_paste, 'drop teardown should restore the original paste handler')

local calls = 0
local dispose = Drop.register(function()
  calls = calls + 1
  return true
end)
assert(Dispatcher.dispatch({ '/missing-drop-path' }, nil))
dispose()
assert(not Dispatcher.dispatch({ '/missing-drop-path' }, nil))
assert(calls == 1, 'disposed drop handler should not run again')

local drag_calls = 0
local dispose_drag = Drop.on_drag(function() drag_calls = drag_calls + 1 end)
Dispatcher.fire_drag({ kind = 'leave' })
dispose_drag()
Dispatcher.fire_drag({ kind = 'leave' })
assert(drag_calls == 1, 'disposed drag listener should not run again')

local saved = {
  n_ce = snapshot_mapping('n', '<C-e>'),
  n_cy = snapshot_mapping('n', '<C-y>'),
  n_wheel = snapshot_mapping('n', '<ScrollWheelDown>'),
  mousescroll = vim.o.mousescroll,
}

vim.keymap.set('n', '<C-e>', '<cmd>let g:vv_scroll_original_e = 1<cr>', { desc = 'original C-e' })
vim.keymap.set('n', '<C-y>', '<cmd>let g:vv_scroll_original_y = 1<cr>', { desc = 'original C-y' })
vim.keymap.set('n', '<ScrollWheelDown>', '<cmd>let g:vv_scroll_original_wheel = 1<cr>', {
  desc = 'original wheel',
})
vim.o.mousescroll = 'ver:7,hor:3'

local Scroll = require('vv-utils.scroll')
local ScrollState = require('vv-utils.scroll.state')
Scroll.setup({ mouse = 'smooth', mouse_step = 4, frame_ms = 50 })

assert(vim.fn.maparg('<C-e>', 'n', false, true).desc == 'vv-scroll: scroll down')
assert(vim.fn.maparg('<ScrollWheelDown>', 'n', false, true).desc == 'vv-scroll: mouse scroll down')
assert(vim.o.mousescroll == 'ver:4,hor:6')

local lines = {}
for index = 1, 100 do lines[index] = 'line' end
vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
Scroll.window(vim.api.nvim_get_current_win(), 20)
assert(next(ScrollState.runtime.win_timer), 'scroll fixture should start an animation timer')

Scroll.disable()
assert(vim.fn.maparg('<C-e>', 'n', false, true).desc == 'original C-e')
assert(vim.fn.maparg('<C-y>', 'n', false, true).desc == 'original C-y')
assert(vim.fn.maparg('<ScrollWheelDown>', 'n', false, true).desc == 'original wheel')
assert(vim.o.mousescroll == 'ver:7,hor:3')
assert(not next(ScrollState.runtime.win_timer), 'disable should close manual scroll timers')
assert(not next(ScrollState.runtime.auto_timer), 'disable should close automatic scroll timers')

Scroll.setup({ mouse = 'smooth', mouse_step = 4, frame_ms = 50 })
vim.o.mousescroll = 'ver:9,hor:1'
Scroll.disable()
assert(vim.o.mousescroll == 'ver:9,hor:1', 'disable must preserve mousescroll changed after vv-scroll')

restore_mapping('n', '<C-e>', saved.n_ce)
restore_mapping('n', '<C-y>', saved.n_cy)
restore_mapping('n', '<ScrollWheelDown>', saved.n_wheel)
vim.o.mousescroll = saved.mousescroll

print('vv-utils global lifecycle: PASS')
