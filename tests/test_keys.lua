-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  source = (vim.env.VV_TEST_REPO .. '/tests/test_keys.lua')
  root = vim.fn.fnamemodify(source, ':p:h:h')
  vim.opt.runtimepath:prepend(root)

  Keys = require('vv-utils.keys')

  vim.g.mapleader = ' '
  vim.g.maplocalleader = '\\'
end)

T["键位组合按修饰符与平台习惯展示"] = function()
  child.lua_func(function()
    local cases = {
      { '<CR>', '↵' },
      { '<C-y>', '^y' },
      { '<M-p>', '⌥p' },
      { '<A-Left>', '⌥Left' },
      { '<S-Tab>', '⇧Tab' },
      { 'K', '⇧K' },
      { '<S-k>', '⇧K' },
      { '<C-S-v>', '^⇧V' },
      { '<S-C-v>', '^⇧V' },
      { '<D-v>', '⌘v' },
      { '<NL>', '^j' },
      { '<C-W>q', '^wq' },
      { '<localleader>r', '\\r' },
      { '<leader>fp', '␠fp' },
      -- keytrans() 把 \ 与 | 记作 <Bslash> / <Bar>，展示层必须还原为字符
      { '<Bar>', '|' },
      { '\\', '\\' },
      -- 带修饰键时剥掉修饰后的键名同样要还原（曾显示 ⌥Bslash / ⌥Bar / ⌥lt / ^Space / ^CR）
      { '<M-\\>', '⌥\\' },
      { '<M-Bslash>', '⌥\\' },
      { '<C-\\>', '^\\' },
      { '<M-Bar>', '⌥|' },
      { '<D-Bar>', '⌘|' },
      { '<M-lt>', '⌥<' },
      { '<C-lt>', '^<' },
      { '<C-Space>', '^␠' },
      { '<M-Space>', '⌥␠' },
      { '<M-S-Space>', '⌥⇧␠' },
      { '<C-CR>', '^↵' },
      { '<M-CR>', '⌥↵' },
      { '<C-M-CR>', '^⌥↵' },
      -- 无语义映射的具名键带修饰键与无修饰键一致：保留 keytrans 名称
      { '<Esc>', 'Esc' },
      { '<Tab>', 'Tab' },
      { '<Nul>', 'Nul' },
      { '<C-Esc>', '^Esc' },
      { '<M-Tab>', '⌥Tab' },
      { '<C-F5>', '^F5' },
      { '<M-kPlus>', '⌥kPlus' },
      { '<M-Up>', '⌥Up' },
      -- <NL> 本身是 Ctrl-J；带修饰时不再叠加 ^ 前缀
      { '<M-NL>', '⌥NL' },
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
  end)
end

return T
