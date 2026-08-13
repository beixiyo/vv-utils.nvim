-- help_panel 公开分类顺序契约回归

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
vim.opt.runtimepath:prepend(root)

local source_buf = vim.api.nvim_create_buf(false, true)
require('vv-utils.help_panel').open({
  source_buf = source_buf,
  desc_prefix = 'fixture: ',
  title = 'Fixture',
  title_icon = 'T',
  title_icon_hl = 'DiagnosticInfo',
  extra_rows = {
    { cat = 'Second', lhs = 'b', action = 'second action', icon = '!', icon_hl = 'DiagnosticWarn' },
    { cat = 'First', lhs = 'a', action = 'first action' },
    { cat = 'Second', lhs = 'c', action = 'another second action' },
  },
})

local help_window = vim.api.nvim_get_current_win()
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
local positions = {}

for index, line in ipairs(lines) do
  local category = line:match('^  (%S+)$')
  if category then positions[category] = index end
end

assert(positions.Second and positions.First and positions.Second < positions.First,
  '未声明的 extra_rows 分类应保持首次出现顺序')
assert(vim.api.nvim_win_get_cursor(help_window)[1] == 4,
  '打开帮助面板后应聚焦首个动作行')

local help_buf = vim.api.nvim_win_get_buf(help_window)
local highlights = vim.api.nvim_buf_get_extmarks(
  help_buf,
  vim.api.nvim_get_namespaces()['vv-utils.help_panel'],
  0,
  -1,
  { details = true }
)
local found_title_icon, found_action_icon = false, false

for _, mark in ipairs(highlights) do
  local details = mark[4]
  if mark[2] == 0 and details.hl_group == 'DiagnosticInfo' then found_title_icon = true end
  if details.hl_group == 'DiagnosticWarn' then found_action_icon = true end
end

assert(found_title_icon, 'title_icon_hl 应用于标题图标')
assert(found_action_icon, 'extra_rows.icon_hl 应用于动作图标')

local config = vim.api.nvim_win_get_config(help_window)
local title_width = vim.fn.strdisplaywidth(vim.trim(lines[1]))
local left_padding = vim.fn.strdisplaywidth(lines[1]:match('^(%s*)'))
local right_padding = config.width - left_padding - title_width
assert(math.abs(left_padding - right_padding) <= 1, '帮助面板标题应相对窗口内容宽度水平居中')
assert(config.width <= math.max(1, vim.o.columns - 4)
    and config.height <= math.max(1, vim.o.lines - 4),
  '帮助浮窗尺寸应受编辑器边界约束')

vim.api.nvim_feedkeys('q', 'xt', false)
assert(not vim.api.nvim_win_is_valid(help_window), 'q 应关闭帮助面板')

print('PASS: vv-utils help_panel 分类、浮窗与关闭行为')
