-- 用真实窗口读回验证局部装饰不会写入新 buffer 的默认副本。
local T, child = dofile('tests/helpers.lua').new_set()

local function check_options(mode, target)
  child.lua_func(function(action, target)
    local api = vim.api
    vim.o.columns, vim.o.lines = 160, 45
    local origin = api.nvim_get_current_win()
    local baseline = { winhighlight = 'Normal:ErrorMsg' }
    local defaults = vim.tbl_extend('force', {
      number = true, relativenumber = true, foldcolumn = '2',
      winhighlight = 'Normal:ErrorMsg', fillchars = 'horiz:Z',
      winbar = 'BASEBAR', statusline = 'BASESTATUS',
    }, baseline)
    for name, value in pairs(defaults) do
      api.nvim_set_option_value(name, value, { win = origin, scope = 'global' })
      api.nvim_set_option_value(name, value, { win = origin, scope = 'local' })
    end
    local function snapshot(win)
      local result = {}
      for name in pairs(defaults) do
        result[name] = {}
        for _, scope in ipairs({ 'local', 'global' }) do
          result[name][scope] = api.nvim_get_option_value(name, { win = win, scope = scope })
        end
      end
      return result
    end
    local original = snapshot(origin)
    local function unchanged()
      assert(vim.deep_equal(snapshot(origin), original), '面板生命周期不得改变原用户窗口的局部值或默认副本')
    end
    local function expect(win, values, scopes, context)
      for name, value in pairs(values) do
        for _, scope in ipairs(scopes) do
          local actual = api.nvim_get_option_value(name, { win = win, scope = scope })
          assert(actual == value, context .. '：' .. name .. '/' .. scope
            .. ' 期望 ' .. vim.inspect(value) .. '，实际 ' .. vim.inspect(actual))
        end
        assert(api.nvim_get_option_value(name, { win = win }) == value, context .. '：有效值不一致 ' .. name)
      end
    end
    local function fresh() return api.nvim_create_buf(true, false) end
    local panel = require('vv-utils.tree_panel').new({
      id = 'options', source = function() return {} end,
      toolbar = { items = { { key = 'q', label = 'Close' } } },
    })
    local function open()
      panel:open()
      return target == '工具栏' and panel.toolbar_win or panel.win
    end
    local function close()
      -- 工具栏正常 BufEnter 会将焦点交回正文；派生探针结束后也从正文关闭。
      if panel:is_open() then api.nvim_set_current_win(panel.win) end
      panel:close()
    end
    local applied = { winhighlight = target == '工具栏'
      and 'Normal:Normal,EndOfBuffer:Normal,StatusLine:Normal,StatusLineNC:Normal,WinSeparator:Normal'
      or 'Normal:Normal,CursorLine:Visual' }
    local win = open()
    expect(win, applied, { 'local' }, '面板应保留自身装饰')
    if target == '工具栏' then
      for _, name in ipairs({ 'fillchars', 'winbar', 'statusline' }) do
        assert(api.nvim_get_option_value(name, { win = win, scope = 'global' }) == defaults[name],
          '工具栏的 global-local 选项不得改写全局基线：' .. name)
      end
    end
    unchanged()
    api.nvim_set_current_win(win)

    if action == '新缓冲浮窗' then
      local derived = api.nvim_open_win(fresh(), false, {
        relative = 'editor', row = 1, col = 1, width = 20, height = 3,
      })
      expect(derived, baseline, { 'local', 'global' }, '派生普通浮窗不得继承面板装饰')
      api.nvim_win_close(derived, true)
    elseif action == '同缓冲分屏后换普通缓冲' then
      vim.cmd('vsplit')
      local derived = api.nvim_get_current_win()
      expect(derived, applied, { 'local' }, '同 buffer 分屏必须保留正常的局部选项复制')
      api.nvim_win_set_buf(derived, fresh())
      expect(derived, baseline, { 'local', 'global' }, '分屏换普通 buffer 必须恢复用户默认副本')
      api.nvim_win_close(derived, true)
    elseif action == '直接换普通缓冲' then
      api.nvim_win_set_buf(win, fresh())
      expect(win, baseline, { 'local', 'global' }, '面板窗口换普通 buffer 不得残留装饰')
    else
      for name, value in pairs(baseline) do
        assert(api.nvim_get_option_value(name, { win = win, scope = 'global' }) == value,
          '打开面板不得改写默认副本：' .. name)
      end
    end
    unchanged()
    close()
    -- 直接替换 buffer 可能先触发 wipe 清理；留下的普通窗口不是插件应强关的资源。
    if api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
    unchanged()
    api.nvim_set_current_win(origin)
    win = open()
    expect(win, applied, { 'local' }, '重开面板应重新设置局部装饰')
    for name, value in pairs(baseline) do
      assert(api.nvim_get_option_value(name, { win = win, scope = 'global' }) == value,
        '重开面板不得改写默认副本：' .. name)
    end
    close()
    unchanged()
  end, mode, target)
end

for _, target in ipairs({ '正文', '工具栏' }) do
  for _, mode in ipairs({ '新缓冲浮窗', '同缓冲分屏后换普通缓冲', '直接换普通缓冲', '关闭重开' }) do
    T[target .. '：' .. mode] = function() check_options(mode, target) end
  end
end

return T
