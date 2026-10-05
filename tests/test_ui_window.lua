-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  this = vim.fn.fnamemodify((vim.env.VV_TEST_REPO .. '/tests/test_ui_window.lua'), ':p')
  plugin_root = vim.fn.fnamemodify(this, ':h:h')
  package.path = table.concat({
    plugin_root .. '/lua/?.lua',
    plugin_root .. '/lua/?/init.lua',
    package.path,
  }, ';')

  UIWindow = require('vv-utils.ui_window')
end)

T["同 buffer 窗口去重且失效首选自动恢复"] = function()
  child.lua_func(function()
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
  end)
end

T["浮窗边框、尺寸、chrome 与幂等关闭"] = function()
  child.lua_func(function()
    local float_buf = vim.api.nvim_create_buf(false, true)
    local float_lines = vim.tbl_map(tostring, vim.fn.range(1, 100))
    vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, float_lines)
    local float = UIWindow.open_float(float_buf, {
      width = vim.o.columns * 2,
      height = vim.o.lines * 2,
      title = ' 固定标题 ',
      footer = ' 固定页脚 ',
      chrome = { cursorline = true },
    })
    local config = vim.api.nvim_win_get_config(float.win)

    assert(config.width == math.max(1, vim.o.columns - 4), '浮窗宽度应受编辑器尺寸约束')
    assert(config.height == math.max(1, vim.o.lines - 4), '浮窗高度应受编辑器尺寸约束')
    assert(config.title[1][1] == ' 固定标题 ', '标题应固定在浮窗边框')
    assert(config.footer[1][1] == ' 固定页脚 ', '页脚应固定在浮窗边框')
    assert(vim.wo[float.win].cursorline, '调用方应能覆盖 window chrome')
    assert(not vim.wo[float.win].number, '浮窗不应显示行号')

    float.close()
    float.close()
    assert(not vim.api.nvim_win_is_valid(float.win), 'close 应可重复调用')
  end)
end

return T
