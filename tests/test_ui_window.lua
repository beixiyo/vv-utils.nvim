-- UI window 不变量验证
-- 运行：nvim --headless -u NONE -l tests/test_ui_window.lua

local this = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
local plugin_root = vim.fn.fnamemodify(this, ':h:h')
package.path = table.concat({
  plugin_root .. '/lua/?.lua',
  plugin_root .. '/lua/?/init.lua',
  package.path,
}, ';')

local UIWindow = require('vv-utils.ui_window')
local tab = vim.api.nvim_get_current_tabpage()
local panel_buf = vim.api.nvim_create_buf(false, true)
local main_buf = vim.api.nvim_create_buf(false, true)

vim.api.nvim_win_set_buf(0, panel_buf)
local keeper = vim.api.nvim_get_current_win()

vim.cmd('belowright split')
local duplicate = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(duplicate, panel_buf)

vim.cmd('rightbelow vsplit')
local main = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(main, main_buf)

local kept, closed = UIWindow.ensure_unique_buffer_window(tab, panel_buf, keeper)
assert(kept == keeper, '应保留 preferred window')
assert(#closed == 1 and closed[1] == duplicate, '应关闭唯一的重复 window')
assert(not vim.api.nvim_win_is_valid(duplicate), '重复 window 仍然有效')
assert(vim.api.nvim_win_is_valid(main), '不相关的主窗口不应被关闭')

local count = 0
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
  if vim.api.nvim_win_get_buf(win) == panel_buf then count = count + 1 end
end
assert(count == 1, 'panel buffer 应只显示一次')

vim.api.nvim_set_current_win(main)
vim.cmd('belowright split')
local late_duplicate = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(late_duplicate, panel_buf)

local recovered, recovered_closed = UIWindow.ensure_unique_buffer_window(tab, panel_buf, duplicate)
assert(recovered == keeper, 'preferred 失效时应复用现存 panel window')
assert(#recovered_closed == 1 and recovered_closed[1] == late_duplicate, '应关闭后出现的 orphan window')

print('[PASS] ui_window: panel buffer window 唯一性')
