-- vv-utils.keys 的键位展示契约测试

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
vim.opt.runtimepath:prepend(root)

local Keys = require('vv-utils.keys')

vim.g.mapleader = ' '
vim.g.maplocalleader = '\\'

local cases = {
  { '<CR>', '↵' },
  { '<C-y>', '^y' },
  { '<M-p>', '⌥p' },
  { '<A-Left>', '⌥Left' },
  { '<S-Tab>', '⇧Tab' },
  { '<C-S-v>', '^⇧V' },
  { '<S-C-v>', '^⇧V' },
  { '<D-v>', '⌘v' },
  { '<NL>', '^j' },
  { '<C-W>q', '^wq' },
  { '<localleader>r', '\\r' },
  { '<leader>fp', '␠fp' },
}

for _, case in ipairs(cases) do
  assert(Keys.display(case[1]) == case[2], case[1] .. ' 应显示为 ' .. case[2])
end

local encoded_ctrl_y = vim.api.nvim_replace_termcodes('<C-y>', true, true, true)
assert(Keys.display(encoded_ctrl_y) == '^y', '已编码 Ctrl+y 应保持紧凑展示')
local encoded_composite = vim.api.nvim_replace_termcodes('<C-W>q', true, true, true)
assert(Keys.display(encoded_composite) == '^wq', '已编码复合键应逐键展示')
assert(Keys.display('<NL>') ~= Keys.display('<CR>'), 'NL 与 CR 不应折叠为同一个标签')
assert(Keys.hint('Confirm', '<C-y>') == 'Confirm ^y', 'hint 应组合动作与键位')

print('vv-utils keys: PASS')
