-- test_state.lua 的跨 Neovim 进程读写夹具

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.runtimepath:prepend(repo)

local path = assert(vim.env.VV_STATE_TEST_PATH)
local mode = assert(vim.env.VV_STATE_TEST_MODE)
local state = require('vv-utils.state').register('cross-process', 'panel', {
  path = path,
})

if mode == 'write' then
  assert(state:set('width', 57))
elseif mode == 'read' then
  assert(state:get('width') == 57, 'a fresh Neovim process did not restore width 57')
else
  error('unknown state process fixture mode: ' .. mode)
end
