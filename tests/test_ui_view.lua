-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  vim.opt.runtimepath:prepend(vim.env.VV_TEST_REPO)
  vim.o.columns, vim.o.lines = 120, 40
  vim.o.termguicolors = true
  vim.api.nvim_set_hl(0, 'Normal', { bg = '#101010', fg = '#eeeeee' })

  View = require('vv-utils.ui_view')
  Rows = require('vv-utils.ui_rows')

  function lines_of(view) return vim.api.nvim_buf_get_lines(view.buf, 0, -1, false) end
  function cursor_text(view)
    return vim.api.nvim_buf_get_lines(view.buf, vim.api.nvim_win_get_cursor(view.win)[1] - 1,
      vim.api.nvim_win_get_cursor(view.win)[1], false)[1]
  end
  function press(keys) vim.api.nvim_feedkeys(vim.keycode(keys), 'mx', false) end
  function floats()
    local result = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative ~= '' then
        result[#result + 1] = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
      end
    end
    table.sort(result)
    return result
  end
end)

T["行工具按显示宽度补齐、截断、对齐并画比例条"] = function()
  child.lua_func(function()
    assert(Rows.width({ { '中文' }, { 'ab' } }) == 6)
    assert(Rows.width(Rows.pad({ { '中' } }, 6)) == 6)
    assert(Rows.pad({ { 'x' } }, 3, 'right')[1][1] == '  ', '右对齐时填充在前')

    local cut = Rows.truncate({ { '中文字符', 'A' }, { 'tail', 'B' } }, 5)
    assert(Rows.width(cut) <= 5 and cut[#cut][1]:sub(-3) == '…', vim.inspect(cut))
    assert(cut[1][2] == 'A', '截断保留片段高亮')

    local aligned = Rows.table({
      { '名称', { { '1.5 ms', 'N' } }, 'tail' },
      { 'longer-name', { { '12.25 ms', 'N' } }, 't' },
    }, { align = { [2] = 'right' } })
    local function text(chunks)
      return table.concat(vim.tbl_map(function(chunk) return chunk[1] end, chunks))
    end
    -- 第三列在两行里起始于同一显示列，且最后一列不补尾随空格
    local first, second = text(aligned[1]), text(aligned[2])
    assert(vim.fn.strdisplaywidth(first:sub(1, first:find('tail', 1, true) - 1))
      == vim.fn.strdisplaywidth(second:sub(1, #second - 1)), first .. '|' .. second)
    assert(first:sub(-4) == 'tail')
    assert(first:find('  1.5 ms', 1, true), '数字列右对齐：' .. first)

    local bar = Rows.bar(0.5, 10)
    assert(Rows.width(bar) == 10 and Rows.width({ bar[1] }) == 5)
    assert(#Rows.bar(0, 10) == 1 and Rows.width({ Rows.bar(0.001, 10)[1] }) == 1, '非零比例至少一格')
    assert(#Rows.bar(2, 10) == 1, '越界比例截到满格')
  end)
end

T["标签、分组、展开详情与动作都围绕条目 id 工作"] = function()
  child.lua_func(function()
    local data = { a = { 'one', 'two', 'three' }, b = { 'solo' } }
    local ran = {}
    local closed = 0
    local view = View.open({
      brand = 'Demo',
      filetype = 'demo-view',
      tabs = { { id = 'a', label = 'Alpha', key = '1' }, { id = 'b', label = 'Beta', key = '2' } },
      page = function(view)
        local items = {}
        for _, name in ipairs(data[view.tab()]) do
          items[#items + 1] = { id = name, row = { { name, 'Identifier' } }, detail = { 'detail of ' .. name, 'more' } }
        end
        return { header = { 'summary line' }, sections = { { id = 'group', title = 'Group', items = items } } }
      end,
      actions = {
        { key = 'x', desc = 'Mark', tab = 'a', run = function(_, item) ran[#ran + 1] = item and item.id or 'none' end },
      },
      on_close = function() closed = closed + 1 end,
    })

    assert(vim.deep_equal(floats(), { 'demo-view', 'vv-backdrop' }), vim.inspect(floats()))
    local content = table.concat(lines_of(view), '\n')
    assert(content:find(' Demo ', 1, true) and content:find(' Alpha (1) ', 1, true), content)
    assert(content:find('Group (3)', 1, true), '分组标题带计数：' .. content)
    assert(cursor_text(view):find('one', 1, true), '打开后光标落在第一个条目：' .. cursor_text(view))
    assert(not vim.bo[view.buf].modifiable)

    -- 动作拿到光标所在条目
    press('j')
    press('x')
    assert(ran[1] == 'two', vim.inspect(ran))

    -- 展开后光标落在详情行上，条目仍是它；动作与再次刷新都不丢位置
    press('<CR>')
    assert(view.is_expanded('two') and table.concat(lines_of(view), '\n'):find('detail of two', 1, true))
    press('j')
    assert(cursor_text(view):find('detail of two', 1, true) and view.item().id == 'two')
    view.refresh()
    assert(cursor_text(view):find('detail of two', 1, true), '重绘后保持在详情行')

    -- 上方插入新条目，光标仍跟着原条目走
    table.insert(data.a, 1, 'zero')
    view.refresh()
    assert(view.item().id == 'two' and view.line_of('zero') < view.line_of('two'))

    -- 从详情行收起，回到条目本身
    press('<CR>')
    assert(not view.is_expanded('two') and cursor_text(view):find('two', 1, true))
    assert(not cursor_text(view):find('detail', 1, true))

    -- 切换标签：限定标签的动作失效，页脚提示随之变化
    local function footer()
      return table.concat(vim.tbl_map(function(chunk) return chunk[1] end,
        vim.api.nvim_win_get_config(view.win).footer or {}))
    end
    assert(footer():find('Mark', 1, true), footer())
    press('2')
    assert(view.tab() == 'b' and view.item().id == 'solo')
    assert(not footer():find('Mark', 1, true), footer())
    press('x')
    assert(#ran == 1, '动作只在声明的标签下生效')
    press('<Tab>')
    assert(view.tab() == 'a')

    -- 终端缩放后窗口跟着重排
    local before = vim.api.nvim_win_get_width(view.win)
    vim.o.columns = 80
    vim.api.nvim_exec_autocmds('VimResized', {})
    vim.wait(100, function() return false end)
    assert(vim.api.nvim_win_get_width(view.win) < before and vim.api.nvim_win_get_width(view.win) <= 80)

    -- 关闭：遮罩一并消失，on_close 只触发一次
    press('q')
    vim.wait(100, function() return #floats() == 0 end)
    assert(#floats() == 0 and not view.is_open(), vim.inspect(floats()))
    view.close()
    assert(closed == 1)
  end)
end

T["外部方式关闭窗口同样收尾，透明背景下不建遮罩"] = function()
  child.lua_func(function()
    local closed = 0
    local view = View.open({
      page = function() return { sections = {}, empty = 'nothing here' } end,
      on_close = function() closed = closed + 1 end,
    })
    assert(table.concat(lines_of(view), '\n'):find('nothing here', 1, true))
    vim.api.nvim_win_close(view.win, true)
    vim.wait(200, function() return closed == 1 and #floats() == 0 end)
    assert(closed == 1 and #floats() == 0, vim.inspect(floats()))

    -- Normal 没有背景色时混合不出压暗效果
    vim.api.nvim_set_hl(0, 'Normal', { fg = '#eeeeee' })
    local plain = View.open({ filetype = 'plain-view', page = function() return { sections = {} } end })
    assert(vim.deep_equal(floats(), { 'plain-view' }), vim.inspect(floats()))
    plain.close()
  end)
end

T["按内容定尺寸、动态标题、内容起始列与同步收尾"] = function()
  child.lua_func(function()
    local names = { 'short', 'a-much-longer-item-name' }
    local order = {}
    local view = View.open({
      width = 'content',
      height = 'content',
      min_width = 20,
      backdrop = false,
      section_keys = false,
      page = function()
        local items = {}
        for _, name in ipairs(names) do items[#items + 1] = { id = name, row = name } end
        return { title = ('Items · %d'):format(#names), sections = { { id = 'all', items = items } } }
      end,
      actions = { { key = { '<CR>', 'r' }, desc = 'Restore', hint = 'all', run = function() end } },
      on_close = function() order[#order + 1] = 'on_close' end,
    })

    -- 没有标签栏和标题的单分组：行数等于条目数，末尾不留空行
    assert(#lines_of(view) == 2 and vim.api.nvim_win_get_height(view.win) == 2, vim.inspect(lines_of(view)))
    local function title()
      return table.concat(vim.tbl_map(function(chunk) return chunk[1] end, vim.api.nvim_win_get_config(view.win).title))
    end
    local function footer()
      return table.concat(vim.tbl_map(function(chunk) return chunk[1] end, vim.api.nvim_win_get_config(view.win).footer))
    end
    assert(title():find('Items · 2', 1, true), title())
    assert(footer():find('↵/r Restore', 1, true), "hint = 'all' 显示全部键：" .. footer())
    assert(not footer():find('…', 1, true), '宽度应容得下完整页脚：' .. footer())
    assert(vim.fn.maparg(']]', 'n', false, true).buffer ~= 1, 'section_keys = false 时不绑分组跳转')

    -- 光标落在内容起始列而不是缩进里；pos_of 给出同一个列
    local line, col = view.pos_of('short')
    assert(line == 1 and col == 2 and vim.api.nvim_win_get_cursor(view.win)[2] == 2)

    -- 内容变化后窗口跟着长高、标题更新
    names[#names + 1] = 'third'
    view.refresh()
    assert(vim.api.nvim_win_get_height(view.win) == 3 and title():find('Items · 3', 1, true))

    -- 外部方式关窗：on_close 在 WinClosed 里同步执行
    vim.api.nvim_win_close(view.win, true)
    assert(order[1] == 'on_close', '外部关窗时调用方收尾不应晚一拍')
  end)
end

T["路径类内容从左侧截断并保留尾部"] = function()
  child.lua_func(function()
    local cut = Rows.truncate({ { '/very/long/', 'Dir' }, { 'path/to/file.lua', 'File' } }, 12, { side = 'left' })
    local text = table.concat(vim.tbl_map(function(chunk) return chunk[1] end, cut))
    assert(text:sub(1, 3) == '…' and text:sub(-8) == 'file.lua', text)
    assert(Rows.width(cut) <= 12 and cut[#cut][2] == 'File')
    assert(#Rows.truncate({ { 'ok' } }, 12, { side = 'left' }) == 1, '未超宽时原样返回')
  end)
end

return T
