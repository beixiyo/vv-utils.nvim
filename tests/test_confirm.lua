-- vv-utils.confirm 的动作选择和关闭生命周期回归测试

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
vim.opt.runtimepath:prepend(root)

local Confirm = require('vv-utils.confirm')
local confirmed = false

Confirm.open({
  title = 'Permanently delete?',
  message = 'This cannot be undone.',
  details = { { label = 'File', value = '/tmp/example.txt' } },
  severity = 'danger',
  confirm_label = 'Delete',
  on_confirm = function() confirmed = true end,
})

local window = vim.api.nvim_get_current_win()
local buffer = vim.api.nvim_win_get_buf(window)
assert(vim.bo[buffer].filetype == 'vv-confirm', '确认框应使用通用 filetype')
assert(
  vim.api.nvim_win_get_config(window).title[1][1] == ' Permanently delete? '
    and vim.api.nvim_win_get_config(window).title[1][2] == 'Title',
  '确认标题应显示在边框外层'
)
local rendered = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
assert(vim.deep_equal({ rendered[1], rendered[2], rendered[3], rendered[4] }, {
  '  This cannot be undone.',
  '',
  '  File',
  '    /tmp/example.txt',
}), '确认框正文不重复标题')
assert(rendered[#rendered]:find('󰄬  ^y  Delete', 1, true)
  and rendered[#rendered]:find('󰜺  q  Cancel', 1, true)
  and not rendered[#rendered]:find('Esc', 1, true),
  '确认框 footer 应包含确认与精简后的取消动作')
assert(vim.fn.strdisplaywidth(rendered[#rendered]) <= vim.api.nvim_win_get_width(window),
  '确认框 footer 不应超出窗口宽度')

local marks = vim.api.nvim_buf_get_extmarks(buffer, -1, 0, -1, { details = true })
local groups = {}
for _, mark in ipairs(marks) do
  groups[mark[4].hl_group] = true
end
assert(groups.DiagnosticError, '危险确认应高亮标题和危险动作')

vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-y>', true, false, true), 'xt', false)
assert(confirmed, 'Ctrl+y 应触发确认回调')
assert(not vim.api.nvim_win_is_valid(window), '选择动作后应关闭浮窗')

local warning = Confirm.open({
  title = 'Discard changes?',
  message = {
    'Tracked changes will be discarded.',
    { icon = '⚠', icon_hl = 'DiagnosticWarn', text = '1 untracked file will be permanently deleted!' },
  },
})
local warning_buffer = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_buf_get_lines(warning_buffer, 0, 2, false)[2]
  == '  ⚠ 1 untracked file will be permanently deleted!', '带图标说明行应保持单数文案')
local warning_marks = vim.api.nvim_buf_get_extmarks(warning_buffer, -1, 0, -1, { details = true })
local has_warning_icon = false
for _, mark in ipairs(warning_marks) do
  if mark[2] == 1 and mark[4].hl_group == 'DiagnosticWarn' then has_warning_icon = true end
end
assert(has_warning_icon, '告警图标应使用 DiagnosticWarn 高亮')
warning.close()

local multiline = Confirm.open({
  title = 'Multiline details?',
  message = 'first line\nsecond line',
  details = { { label = 'Command', value = 'before\nafter\r\nlast' } },
  window = { max_width = 32 },
})
local multiline_window = vim.api.nvim_get_current_win()
local multiline_buffer = vim.api.nvim_get_current_buf()
local multiline_lines = vim.api.nvim_buf_get_lines(multiline_buffer, 0, -1, false)
local joined_multiline = table.concat(multiline_lines, '\n')
assert(joined_multiline:find('    before\n    after\n    last', 1, true),
  '详情值中的换行应拆成缩进后的 buffer 行')
for _, line in ipairs(multiline_lines) do
  assert(vim.fn.strdisplaywidth(line) <= vim.api.nvim_win_get_width(multiline_window),
    '多行详情不应制造超出窗口的物理行')
end
multiline.close()

local narrow = Confirm.open({
  title = 'Narrow?',
  message = 'short body',
  window = { max_width = 20 },
})
local narrow_window = vim.api.nvim_get_current_win()
local narrow_buffer = vim.api.nvim_get_current_buf()
local narrow_lines = vim.api.nvim_buf_get_lines(narrow_buffer, 0, -1, false)
assert(vim.api.nvim_win_get_width(narrow_window) == 20, '窄确认框应尊重 max_width')
for _, line in ipairs(narrow_lines) do
  assert(vim.fn.strdisplaywidth(line) <= 20, '窄确认框 footer 不应横向溢出')
end
local narrow_cursor_line = vim.api.nvim_win_get_cursor(narrow_window)[1]
assert(narrow_cursor_line >= 3, '窄确认框初始视口应落在 footer')
assert(table.concat(narrow_lines):gsub('%s', ''):find('Cancel', 1, true),
  '窄确认框 footer 应保留取消动作')
narrow.close()

for _, requested_width in ipairs({ 2, 3 }) do
  local tiny = Confirm.open({
    title = 'Tiny?',
    confirm_icon = '宽',
    cancel_icon = '宽',
    window = { max_width = requested_width },
  })
  local tiny_window = vim.api.nvim_get_current_win()
  local tiny_buffer = vim.api.nvim_get_current_buf()
  local actual_width = vim.api.nvim_win_get_width(tiny_window)
  assert(actual_width >= requested_width, '过小 max_width 应明确归一化')
  for _, line in ipairs(vim.api.nvim_buf_get_lines(tiny_buffer, 0, -1, false)) do
    assert(vim.fn.strdisplaywidth(line) <= actual_width,
      '过小 max_width 和宽 Unicode footer 不应产生溢出行')
  end
  tiny.close()
end

local long_label = string.rep('X', 40)
local long_footer = Confirm.open({
  title = 'Long labels?',
  confirm_icon = '',
  cancel_icon = '',
  confirm_label = long_label,
  cancel_label = 'C',
  confirm_hl = 'DiagnosticWarn',
  window = { max_width = 18 },
})
local long_footer_buffer = vim.api.nvim_get_current_buf()
local long_footer_marks = vim.api.nvim_buf_get_extmarks(long_footer_buffer, -1, 0, -1, { details = true })
local highlighted_label_bytes = 0
local long_footer_lines = vim.api.nvim_buf_get_lines(long_footer_buffer, 0, -1, false)
for _, mark in ipairs(long_footer_marks) do
  if mark[4].hl_group == 'DiagnosticWarn' then
    local line = long_footer_lines[mark[2] + 1]
    local text = line:sub(mark[3] + 1, mark[4].end_col)
    highlighted_label_bytes = highlighted_label_bytes + select(2, text:gsub('X', ''))
  end
end
assert(highlighted_label_bytes == #long_label,
  '确认 footer 的长标签拆行后仍应完整保留语义高亮')
long_footer.close()

local cancelled = false
local handle = Confirm.open({
  title = 'Cancel?',
  on_cancel = function() cancelled = true end,
})
local close_window = vim.api.nvim_get_current_win()
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
assert(not vim.api.nvim_win_is_valid(close_window), '取消后应关闭浮窗')
assert(cancelled, 'Enter 应取消确认框')

cancelled = false
Confirm.open({
  title = 'Cancel with Ctrl+c?',
  on_cancel = function() cancelled = true end,
})
close_window = vim.api.nvim_get_current_win()
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-c>', true, false, true), 'xt', false)
assert(not vim.api.nvim_win_is_valid(close_window) and cancelled,
  'Ctrl+c 应执行默认取消动作并关闭确认框')

require('vv-utils').setup({
  confirm = {
    actions = {
      confirm = { keys = 'x', hint = 'x' },
      cancel = { keys = { 'z', '<Esc>' }, hint = 'z' },
    },
  },
})
confirmed = false
Confirm.open({ title = 'Custom keys?', on_confirm = function() confirmed = true end })
close_window = vim.api.nvim_get_current_win()
vim.api.nvim_feedkeys('x', 'xt', false)
assert(not vim.api.nvim_win_is_valid(close_window) and confirmed,
  '全局自定义确认键应通过真实 buffer 映射触发生产回调')

Confirm.open({
  title = 'Local hint?',
  actions = { confirm = { hint = 'X' } },
})
close_window = vim.api.nvim_get_current_win()
buffer = vim.api.nvim_get_current_buf()
rendered = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
assert(rendered[#rendered]:find('X', 1, true), '单次 hint 覆盖应反映在实际 footer')
vim.api.nvim_feedkeys('x', 'xt', false)
assert(not vim.api.nvim_win_is_valid(close_window), '单次只覆盖 hint 时应保留全局确认键')

local ok, conflict = pcall(Confirm.open, {
  title = 'Conflict?',
  actions = { confirm = { keys = 'z' } },
})
assert(not ok and tostring(conflict):find('assigned to both confirm and cancel', 1, true),
  '确认与取消动作的冲突键应在打开窗口前拒绝')
Confirm.setup()

handle = Confirm.open({ title = 'Close?' })
close_window = vim.api.nvim_get_current_win()
handle.close()
handle.close()
assert(not vim.api.nvim_win_is_valid(close_window), 'handle.close 应幂等关闭浮窗')

handle = Confirm.open({
  title = 'Long text?',
  message = string.rep('long text ', 12),
  window = { max_width = 48 },
})
local long_window = vim.api.nvim_get_current_win()
assert(vim.api.nvim_win_get_width(long_window) == 48, '长文本应受 max_width 限制')
assert(vim.api.nvim_win_get_height(long_window) > 3, '长文本换行后应增加窗口高度')
local long_buffer = vim.api.nvim_get_current_buf()
local long_cursor_line = vim.api.nvim_win_get_cursor(long_window)[1]
local long_lines = vim.api.nvim_buf_get_lines(long_buffer, 0, -1, false)
assert(long_lines[long_cursor_line]:find('Cancel', 1, true),
  '正文过长时初始视口仍应显示 footer')
handle.close()

print('vv-utils confirm: PASS')
