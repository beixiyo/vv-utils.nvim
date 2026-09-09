-- 通用 Modal 的正文、动作校验与关闭生命周期回归测试

local this = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
local plugin_root = vim.fn.fnamemodify(this, ':h:h')
package.path = table.concat({
  plugin_root .. '/lua/?.lua',
  plugin_root .. '/lua/?/init.lua',
  package.path,
}, ';')

local Modal = require('vv-utils.modal')

local selected
local handle = Modal.open({
  title = 'Paste Conflict',
  body = {
    { chunks = { { 'Source ', 'Comment' }, { 'project', 'Directory' } } },
    { text = 'The destination already exists.', hl = 'DiagnosticWarn' },
  },
  actions = {
    { id = 'overwrite', label = 'Overwrite', keys = { '1', '<C-1>' }, hl = 'DiagnosticError' },
    { id = 'increment', label = 'Keep Both', keys = { '2', '<C-2>' }, hl = 'DiagnosticOk' },
  },
  cancel = { label = 'Cancel', keys = { 'q', '<Esc>' } },
  on_select = function(id) selected = id end,
})

local window = vim.api.nvim_get_current_win()
local buffer = vim.api.nvim_win_get_buf(window)
assert(handle.is_open(), 'Modal handle should report an open window')
assert(vim.bo[buffer].filetype == 'vv-modal', 'Modal should use its default filetype')
local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
assert(lines[1] == '  Source project' and table.concat(lines, '\n'):find('Overwrite', 1, true),
  'Modal should render body chunks and ordered action footer')
local marks = vim.api.nvim_buf_get_extmarks(buffer, -1, 0, -1, { details = true })
local found_directory = false
for _, mark in ipairs(marks) do
  if mark[4].hl_group == 'Directory' then found_directory = true end
end
assert(found_directory, 'Modal body chunks should receive semantic highlights')

vim.api.nvim_feedkeys('1', 'xt', false)
assert(selected == 'overwrite' and not handle.is_open() and not vim.api.nvim_win_is_valid(window),
  'Selecting an action should close the window before invoking the callback')
handle.close()

local rendered_context
local cancelled = false
handle = Modal.open({
  title = 'Render callback',
  context = { value = 'generated' },
  render = function(ctx)
    rendered_context = ctx
    return { { text = ctx.value, hl = 'String' } }
  end,
  actions = { { id = 'ok', label = 'OK', keys = 'o' } },
  on_cancel = function() cancelled = true end,
})
assert(rendered_context.value == 'generated', 'render callback should receive explicit context')
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'xt', false)
assert(cancelled and not handle.is_open(), 'cancel should close and invoke on_cancel')

local ok, err = pcall(Modal.open, {
  title = 'Conflict',
  actions = {
    { id = 'a', label = 'A', keys = 'x' },
    { id = 'b', label = 'B', keys = 'x' },
  },
})
assert(not ok and tostring(err):find('assigned to both', 1, true), 'conflicting action keys should be rejected')

local multiline_cancelled = 0
handle = Modal.open({
  title = 'Multiline rows',
  body = {
    { chunks = { { 'first\nsecond', 'DiagnosticError' }, { ' tail', 'String' } } },
    { virt_text = { { ' [status]', 'Comment' } }, virt_text_pos = 'eol' },
  },
  actions = { { id = 'ok', label = 'OK', keys = 'o' } },
  on_cancel = function() multiline_cancelled = multiline_cancelled + 1 end,
})
window = vim.api.nvim_get_current_win()
buffer = vim.api.nvim_win_get_buf(window)
lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
assert(lines[1] == '  first' and lines[2] == '  second tail',
  'newline chunks should expand into indented physical lines')
assert(lines[3] == '', 'virt_text-only rows should retain an empty physical line')
marks = vim.api.nvim_buf_get_extmarks(buffer, -1, 0, -1, { details = true })
local first_error, second_error, tail_string, status_virtual = false, false, false, false
for _, mark in ipairs(marks) do
  local details = mark[4]
  if details.hl_group == 'DiagnosticError' and mark[3] == 2 then first_error = true end
  if details.hl_group == 'DiagnosticError' and mark[3] == 2 and mark[2] == 1 then second_error = true end
  if details.hl_group == 'String' and mark[3] == 8 and mark[2] == 1 then tail_string = true end
  if details.virt_text and details.virt_text[1][1] == ' [status]' and mark[2] == 2 then
    status_virtual = true
  end
end
assert(first_error and second_error and tail_string and status_virtual,
  'expanded rows should preserve chunk highlights and virtual text marks')
handle.close()
assert(multiline_cancelled == 0, 'handle.close should not invoke on_cancel')

local externally_cancelled = 0
handle = Modal.open({
  title = 'External close',
  actions = { { id = 'ok', label = 'OK', keys = 'o' } },
  on_cancel = function() externally_cancelled = externally_cancelled + 1 end,
})
vim.cmd('close')
assert(not handle.is_open() and externally_cancelled == 1,
  'external window close should invoke on_cancel exactly once')
handle.close()
assert(externally_cancelled == 1, 'repeated close after external close should stay quiet')

print('vv-utils modal: PASS')
