-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  source = (vim.env.VV_TEST_REPO .. '/tests/test_ui_peek_hints.lua')
  root = vim.fn.fnamemodify(source, ':p:h:h')
  vim.opt.runtimepath:prepend(root)
  vim.o.columns, vim.o.lines = 160, 48

  Peek = require('vv-utils.ui_peek')
  Loading = require('vv-utils.loading')

  lines = {}
  for index = 1, 20 do lines[index] = 'line ' .. index end

  hints = {
    { key = '<CR>', desc = 'Jump' },
    { key = ']p', desc = 'Next' },
    { key = '[p', desc = 'Prev' },
    { key = 'q', desc = 'Close' },
  }

  function footer(win) return vim.api.nvim_win_get_config(win).footer end

  function text(chunks)
    local parts = {}
    for _, chunk in ipairs(chunks or {}) do parts[#parts + 1] = chunk[1] end
    return table.concat(parts)
  end
end)

T["提示文字与按键分别高亮并随窗口宽度重算"] = function()
  child.lua_func(function()
    Peek.setup({ hints = hints })
    local shown = assert(Peek.show({ lines = lines }))
    local chunks = footer(shown.win)
    assert(text(chunks) == ' ↵ Jump  ]p Next  [p Prev  q Close ', '完整提示应写入 footer：' .. vim.inspect(chunks))
    assert(chunks[2][1] == '↵' and chunks[2][2] == 'VVKeyHint', 'key 应使用 VVKeyHint：' .. vim.inspect(chunks))
    assert(chunks[3][1] == ' Jump' and chunks[3][2] == 'VVKeyHintDesc', 'desc 应使用 VVKeyHintDesc：' .. vim.inspect(chunks))
    assert(vim.api.nvim_win_get_config(shown.win).footer_pos == 'center', 'footer_pos 默认 center')
    assert(vim.api.nvim_get_hl(0, { name = 'VVKeyHint' }).link == 'Special', 'VVKeyHint 默认链接 Special')

    -- 窄窗口：整条丢弃尾部条目并追加省略号，任何保留的 key 都完整，总宽不超过窗口
    shown = assert(Peek.show({ lines = lines }, { width = 22, min_width = 10, max_width = 22 }))
    local narrow = text(footer(shown.win))
    assert(narrow == ' ↵ Jump  ]p Next  … ', '窄窗口应整条截断：' .. vim.inspect(narrow))
    assert(vim.fn.strdisplaywidth(narrow) <= vim.api.nvim_win_get_width(shown.win), 'footer 不得超过窗口宽度')

    -- 尺寸变化后按实际宽度重算（外部改窗口宽度，经 WinResized 触发）
    -- -l 脚本不进入主循环，WinResized 不会自动派发（RPC 驱动的真实主循环中浮窗改宽会触发），这里手动派发
    vim.api.nvim_win_set_config(shown.win, { width = 60 })
    vim.api.nvim_exec_autocmds('WinResized', {})
    assert(text(footer(shown.win)) == ' ↵ Jump  ]p Next  [p Prev  q Close ', '放宽后应恢复全部提示：'
      .. vim.inspect(footer(shown.win)))
  end)
end

T["提示列表整体覆盖与禁用清空复用窗口页脚"] = function()
  child.lua_func(function()
    -- override.hints 整体替换 setup 列表，不按下标与 setup 的尾部条目合并
    shown = assert(Peek.show({ lines = lines }, { hints = { { key = 'q', desc = 'Close' } } }))
    assert(text(footer(shown.win)) == ' q Close ', 'override 较短列表不应残留 setup 条目：'
      .. vim.inspect(footer(shown.win)))

    -- hints = false 时清空复用窗口上次写入的 footer
    shown = assert(Peek.show({ lines = lines }, { hints = false }))
    assert(footer(shown.win) == nil, 'hints = false 应清空 footer：' .. vim.inspect(footer(shown.win)))
  end)
end

T["加载接管期间不覆盖帧且停止后恢复提示"] = function()
  child.lua_func(function()
    shown = assert(Peek.show({ lines = lines }))
    local expected = vim.deepcopy(footer(shown.win))
    local loading = Loading.win_text({ win = shown.win, slot = 'footer', label = 'Loading', interval_ms = 10000 })
    assert(text(footer(shown.win)):find('Loading', 1, true), 'loading 帧应写入 footer')
    vim.api.nvim_exec_autocmds('VimResized', {})
    assert(text(footer(shown.win)):find('Loading', 1, true), '无变化的重算不得覆盖 loading 帧')
    loading:stop()
    assert(vim.deep_equal(footer(shown.win), expected), 'loading 结束后应恢复提示：' .. vim.inspect(footer(shown.win)))
  end)
end

return T
