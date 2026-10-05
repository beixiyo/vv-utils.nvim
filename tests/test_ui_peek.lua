-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  source = (vim.env.VV_TEST_REPO .. '/tests/test_ui_peek.lua')
  root = vim.fn.fnamemodify(source, ':p:h:h')
  vim.opt.runtimepath:prepend(root)
  vim.o.columns, vim.o.lines = 160, 48
  -- 模拟用户真实环境：全局 statuscolumn 自绘 + 双行号
  vim.o.statuscolumn = "%!v:lua.require'vv-statuscol'.get()"
  vim.o.number = true
  vim.o.relativenumber = true

  Peek = require('vv-utils.ui_peek')
  source_win = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'local iface = require("iface")', 'return iface' })
  vim.api.nvim_win_set_cursor(source_win, { 1, 6 })

  content = {}
  for index = 1, 30 do
    content[index] = 'local value' .. index .. ' = ' .. index
  end
  content[12] = 'function impl() return value1 end'

  function key(keys)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'xt', false)
  end
end)

T["快照预览范围、窗口复用与本次映射覆盖"] = function()
  child.lua_func(function()
    local shown = Peek.show({
      lines = content,
      filetype = 'lua',
      range = { start = { line = 11, character = 9 }, ['end'] = { line = 11, character = 17 } },
    })
    assert(shown and Peek.is_open(), 'show 应打开浮窗')
    assert(vim.api.nvim_get_current_win() == shown.win, 'enter 默认应聚焦浮窗')
    assert(
      vim.api.nvim_buf_get_lines(shown.buf, 0, -1, false)[12] == content[12],
      '浮窗应显示快照内容'
    )
    assert(vim.wo[shown.win].number == true, '浮窗应默认显示行号')
    assert(vim.wo[shown.win].statuscolumn == '', '浮窗不应继承全局 statuscolumn 自绘')
    assert(vim.wo[shown.win].relativenumber == true, 'relativenumber 应跟随全局设置')
    assert(vim.deep_equal(vim.api.nvim_win_get_cursor(shown.win), { 12, 9 }), '光标应落在 range 起始（utf-16 → byte）')
    local marks = vim.api.nvim_buf_get_extmarks(shown.buf, -1, 0, -1, { details = true })
    assert(#marks >= 1, 'range 落点应绘制高亮 extmark')

    -- 复用：二次 show 同一浮窗与快照 buffer，键位按新配置重设
    local custom_key_hit = false
    local second = Peek.show({
      lines = { 'other content' },
      filetype = 'lua',
      title = 'second',
    }, {
      keys = { ['x'] = function() custom_key_hit = true end },
    })
    assert(second.win == shown.win and second.buf == shown.buf, '应复用浮窗与快照 buffer')
    assert(vim.api.nvim_buf_get_lines(second.buf, 0, -1, false)[1] == 'other content', '内容应替换')
    assert(not vim.fn.maparg('x', 'n', false, false):find('x'), 'x 未按前不应有副作用')
    vim.api.nvim_feedkeys('x', 'xt', false)
    assert(custom_key_hit, 'override keys 应在本次 show 生效')
  end)
end

T["函数尺寸、比例限制、位置与标题策略"] = function()
  child.lua_func(function()
    local seen_ctx = nil
    Peek.show({
      lines = content,
      range = { start = { line = 11, character = 0 }, ['end'] = { line = 11, character = 4 } },
    }, {
      height = function(ctx)
        seen_ctx = ctx
        return ctx.span + 10
      end,
      min_height = function(ctx) return math.max(10, math.floor(ctx.screen.available / 2)) end,
      max_height = function(ctx) return math.floor(ctx.screen.available * 0.75) end,
      min_width = 60,
      max_width = function(ctx) return math.floor(ctx.screen.columns * 0.8) end,
    })
    assert(seen_ctx and seen_ctx.span == 1 and seen_ctx.line_count == 30, 'ctx 应携带 span 与行数')
    assert(seen_ctx.max_line_width >= vim.fn.strdisplaywidth(content[12]), 'ctx 应采样最长行宽度')
    local cfg = vim.api.nvim_win_get_config(Peek.current().win)
    assert(cfg.height == math.max(seen_ctx.span + 10, math.floor(seen_ctx.screen.available / 2)), '函数 min_height 应抬高高度')
    assert(cfg.width >= 60, '函数 min_width 应生效')

    -- ratio：宽度类按 editor 列数、高度类按可用行数换算；作目标值与作上限各自生效，非法值回退
    local available = seen_ctx.screen.available
    Peek.show({ lines = content }, {
      width = { ratio = 0.5 },
      height = function() return { ratio = 0.4 } end,
      min_height = 1,
    })
    cfg = vim.api.nvim_win_get_config(Peek.current().win)
    assert(
      cfg.width == math.floor(vim.o.columns * 0.5) and cfg.height == math.floor(available * 0.4),
      ('ratio 作目标值应按 editor 比例换算，实际 %dx%d'):format(cfg.width, cfg.height)
    )
    Peek.show({ lines = { string.rep('x', 150) } }, { max_width = { ratio = 0.25 }, min_width = 10 })
    cfg = vim.api.nvim_win_get_config(Peek.current().win)
    assert(cfg.width == math.floor(vim.o.columns * 0.25), 'ratio 作上限应夹住内容宽度')
    Peek.show({ lines = { 'short' } }, { width = { ratio = 2 }, min_width = 10 })
    cfg = vim.api.nvim_win_get_config(Peek.current().win)
    assert(cfg.width < vim.o.columns, '非法 ratio 应回退为内容自适应宽度')

    -- position 函数配置：完全接管锚点
    Peek.show({ lines = content }, {
      position = function(ctx) return { anchor = 'NW', row = 5, col = 10 } end,
    })
    cfg = vim.api.nvim_win_get_config(Peek.current().win)
    assert(cfg.anchor == 'NW' and cfg.row == 5 and cfg.col == 10, 'position 函数应接管锚点')

    -- title 支持 fun(ctx)，且 item.title 优先于 setup title
    Peek.show({ lines = content, title = function(ctx) return 'item:' .. ctx.line_count end }, {
      title = 'setup-title',
    })
    cfg = vim.api.nvim_win_get_config(Peek.current().win)
    assert(cfg.title and cfg.title[1][1] == 'item:30', 'item.title 函数应优先于 setup title')
  end)
end

T["关闭恢复源窗口且取消关闭键不会沿用旧回调"] = function()
  child.lua_func(function()
    Peek.show({ lines = content })
    local closed = 0
    Peek.setup({ on_close = function() closed = closed + 1 end })
    key('q')
    assert(not Peek.is_open(), 'q 应关闭浮窗')
    assert(vim.api.nvim_get_current_win() == source_win, '关闭后焦点应回源窗口')
    assert(closed == 1, 'on_close 应触发')

    -- close_keys = false 禁用默认键
    Peek.setup({ close_keys = false })
    Peek.show({ lines = content })
    key('q')
    assert(Peek.is_open(), 'close_keys=false 时 q 不应关闭')
    Peek.close(true)
    assert(not Peek.is_open() and closed == 1, 'close 后不应重复触发 setup 之前的 on_close')

    -- 空内容：不打开浮窗并返回错误
    local empty, err = Peek.show({ lines = {} })
    assert(empty == nil and err == 'empty content', '空内容应返回错误')
    assert(not Peek.is_open(), '空内容不应打开浮窗')
  end)
end

T["URI 文件内容与自绘行切换不残留装饰"] = function()
  child.lua_func(function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local file = dir .. '/fixture.lua'
    vim.fn.writefile(content, file)
    Peek.show({ uri = 'file://' .. file, range = { start = { line = 11, character = 9 }, ['end'] = { line = 11, character = 17 } } })
    assert(Peek.is_open(), 'uri 内容应打开浮窗')
    assert(vim.bo[Peek.current().buf].filetype == 'lua', '应按文件名检测 filetype')
    assert(vim.api.nvim_win_get_cursor(Peek.current().win)[1] == 12, '光标应落到 uri 内容的 range 起点')
    Peek.close()

    -- rows 自绘：chunks 高亮、virt_text、换行展开与 range 叠加；不叠加语法高亮猜测
    local ns = vim.api.nvim_get_namespaces()['vv-utils.ui_peek']
    local rows_info = Peek.show({
      rows = {
        { chunks = { { 'No implementations\n', 'DiagnosticWarn' }, { 'hint', 'Comment' } } },
        { text = 'interface Foo {}', hl = 'Comment', virt_text = { { ' 2 refs', 'Special' } } },
      },
      range = { start = { line = 2, character = 10 }, ['end'] = { line = 2, character = 13 } },
    })
    assert(rows_info and Peek.is_open(), 'rows 应打开浮窗')
    local rows_buf = rows_info.buf
    local row_lines = vim.api.nvim_buf_get_lines(rows_buf, 0, -1, false)
    assert(#row_lines == 3 and row_lines[1] == 'No implementations' and row_lines[3] == 'interface Foo {}', 'rows 换行应展开为物理行')
    assert(vim.bo[rows_buf].filetype == '', 'rows 模式不应猜测 filetype')
    local row_marks = vim.api.nvim_buf_get_extmarks(rows_buf, ns, 0, -1, { details = true })
    local has_virt, has_range_hl = false, false
    for _, mark in ipairs(row_marks) do
      local details = mark[4] or {}
      if details.virt_text then has_virt = true end
      if details.hl_group == 'CurSearch' and (details.priority or 0) >= 5000 then has_range_hl = true end
    end
    assert(has_virt, 'rows 的 virt_text 应渲染')
    assert(has_range_hl, 'range 高亮应叠加在 rows 高亮之上（priority ≥ 5000）')
    assert(vim.api.nvim_win_get_cursor(rows_info.win)[1] == 3, 'rows 光标应落在 range 物理行')

    -- rows → uri 切换：复用 buffer 时旧 rows 高亮被清、filetype 恢复检测
    Peek.show({ uri = 'file://' .. file })
    assert(vim.bo[Peek.current().buf].filetype == 'lua', '切回 uri 应恢复 filetype')
    local after_marks = vim.api.nvim_buf_get_extmarks(Peek.current().buf, ns, 0, -1, { details = true })
    local stale_virt = false
    for _, mark in ipairs(after_marks) do
      if (mark[4] or {}).virt_text then stale_virt = true end
    end
    assert(not stale_virt, 'rows 残留的自绘高亮应随内容替换清除')
    assert(vim.api.nvim_buf_get_lines(Peek.current().buf, 0, 1, false)[1] == content[1], '内容应替换为文件首行')
    Peek.close()
  end)
end

T["来源窗口关闭后预览一同关闭"] = function()
  child.lua_func(function()
    vim.api.nvim_set_current_win(source_win)
    vim.cmd('vsplit')
    Peek.show({ lines = content, source_win = source_win })
    assert(Peek.is_open(), 'source_win 指定时浮窗应打开')
    vim.api.nvim_win_close(source_win, false)
    assert(not Peek.is_open(), '源窗口关闭后浮窗应一并关闭')
  end)
end

return T
