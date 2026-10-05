-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  this = vim.fn.fnamemodify((vim.env.VV_TEST_REPO .. '/tests/test_tree_panel.lua'), ':p')
  plugin_root = vim.fn.fnamemodify(this, ':h:h')
  package.path = table.concat({
    plugin_root .. '/lua/?.lua',
    plugin_root .. '/lua/?/init.lua',
    package.path,
  }, ';')

  Model = require('vv-utils.tree_panel.model')
  State = require('vv-utils.state')
  TreePanel = require('vv-utils.tree_panel')
  nodes = {
    {
      id = 'file:a',
      children = {
        { id = 'ref:a:1' },
        { id = 'ref:a:2' },
      },
    },
    {
      id = 'file:b',
      expanded = false,
      children = {
        { id = 'ref:b:1' },
      },
    },
  }
end)

T["树模型折叠、父子关系与节点校验"] = function()
  child.lua_func(function()
    local folded = {}
    local rows = Model.flatten(nodes, folded)
    assert(#rows == 4, '默认应展开 file:a 并折叠 file:b')
    assert(rows[2].depth == 1 and rows[2].parent.id == 'file:a', '子节点层级或父节点错误')
    assert(#Model.flatten(nil, {}) == 0, 'nil 节点集合应视为空树')

    folded['file:a'] = true
    rows = Model.flatten(nodes, folded)
    assert(#rows == 2, '显式折叠后只应显示根节点')

    Model.fold_all(nodes, folded, false)
    rows = Model.flatten(nodes, folded)
    assert(#rows == 5, '展开全部应显示所有节点')
    assert(#Model.flatten({ {
      id = 'closed-by-default',
      expanded = false,
      children = { { id = 'forced-child' } },
    } }, { ['closed-by-default'] = false }) == 2, '显式折叠状态应覆盖节点默认值')

    local ok, err = pcall(Model.flatten, {
      { id = 'same' },
      { id = 'parent', children = { { id = 'same' } } },
    }, {})
    assert(not ok and tostring(err):find('duplicate'), '跨层级重复 id 应被拒绝')
    assert(not pcall(Model.flatten, { { id = '' } }, {}), '空节点 id 应被拒绝')
  end)
end

T["节点导航循环与无 parser 语法回退"] = function()
  child.lua_func(function()
    local navigation_lines = { 2, 4, 7 }
    assert(Model.move_target(navigation_lines, 2, 1) == 4, '向下移动应选择下一节点')
    assert(Model.move_target(navigation_lines, 7, 1) == 2, '向下越界应循环到首节点')
    assert(Model.move_target(navigation_lines, 2, -1) == 7, '向上越界应循环到尾节点')
    assert(Model.move_target(navigation_lines, 1, 1) == 2, '从 header 向下应进入首节点')
    assert(Model.move_target(navigation_lines, 5, -1) == 4, '从非节点行向上应进入最近节点')
    assert(Model.move_target(navigation_lines, 2, 1, 5) == 7, 'count 移动应正确循环')
    assert(Model.move_target({}, 1, 1) == nil, '空节点集合不可导航')
    assert(not pcall(Model.move_target, navigation_lines, 2, 0), '非法移动方向应被拒绝')

    local fallback_chunks = TreePanel.syntax_chunks('const value = 1', '__missing_parser__', 'Normal')
    assert(#fallback_chunks == 1 and fallback_chunks[1][1] == 'const value = 1'
        and fallback_chunks[1][2] == 'Normal',
      '缺失 parser 时源码高亮应完整降级为 fallback chunk')
    local empty_chunks = TreePanel.syntax_chunks('', 'lua', 'Comment')
    assert(#empty_chunks == 1 and empty_chunks[1][1] == '' and empty_chunks[1][2] == 'Comment',
      '空源码应保留调用方指定的 fallback 高亮')
  end)
end

T["来源预览恢复、宽度持久化与映射帮助"] = function()
  child.lua_func(function()
    local original_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, original_buf)
    local target = vim.fn.tempname() .. '.lua'
    local state_path = vim.fn.tempname()
    local panel_state = State.register('vv-utils-test', 'tree-panel', {
      path = state_path,
    })
    vim.fn.writefile({ 'local target = true' }, target)

    local panel = TreePanel.new({
      id = 'test-preview',
      state = panel_state,
      source = function()
        return {
          {
            id = 'target',
            label = 'target.lua',
            location = { file = target, row = 1, col = 6 },
          },
        }
      end,
    })
    panel:open()
    assert(vim.fn.maparg('<CR>', 'n', false, true).buffer ~= 1,
      '未传 mappings 时 tree panel 不应注册快捷键')
    panel:_preview_cursor()
    assert(vim.uv.fs_realpath(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(panel.source_win)))
        == vim.uv.fs_realpath(target),
      '选择文件节点后应在来源窗口预览')
    panel:close()
    assert(vim.api.nvim_win_get_buf(panel.source_win) == original_buf, '关闭侧栏应恢复来源 buffer')

    panel:open()
    panel:_preview_cursor()
    assert(vim.uv.fs_realpath(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(panel.source_win)))
        == vim.uv.fs_realpath(target),
      '同一 panel 再次打开后仍应支持预览')
    vim.cmd('vertical resize 37')
    panel:close()

    local custom_mapping_context
    local reloaded_panel = TreePanel.new({
      id = 'test-reloaded',
      state = panel_state,
      on_attach = function(current)
        TreePanel.apply_default_mappings(current, { q = false })
        TreePanel.apply_mappings(current, {
          gx = function(ctx) custom_mapping_context = ctx end,
          gy = {
            callback = function(ctx) custom_mapping_context = ctx end,
            desc = 'inspect_node',
          },
        })
      end,
      source = function() return {} end,
    })
    reloaded_panel:open()
    assert(vim.api.nvim_win_get_width(reloaded_panel.win) == 37,
      '新 panel 实例应从共享状态恢复用户实际 resize 的宽度')
    assert(vim.fn.maparg('<CR>', 'n', false, true).buffer == 1
        and vim.fn.maparg('q', 'n', false, true).buffer ~= 1
        and vim.fn.maparg('gx', 'n', false, true).buffer == 1
        and vim.fn.maparg('gy', 'n', false, true).desc == 'vv-tree-panel: inspect_node'
        and vim.fn.maparg('j', 'n', false, true).buffer == 1
        and vim.fn.maparg('<C-N>', 'n', false, true).buffer == 1
        and vim.fn.maparg('gf', 'n', false, true).buffer == 1
        and vim.fn.maparg('g?', 'n', false, true).buffer == 1,
      '调用方应能采用默认映射并覆盖或禁用单个按键')
    vim.fn.maparg('gx', 'n', false, true).callback()
    assert(custom_mapping_context and custom_mapping_context.panel == reloaded_panel,
      '自定义映射回调应收到 panel context')

    vim.fn.maparg('g?', 'n', false, true).callback()
    assert(vim.bo.filetype == 'vv-tree-panel-help', 'g? 应打开通用快捷键帮助')
    assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('inspect node', 1, true),
      'mapping spec 的 desc 应进入通用帮助')
    vim.fn.maparg('q', 'n', false, true).callback()
    assert(vim.api.nvim_get_current_win() == reloaded_panel.win, '关闭帮助后应回到 tree panel')

    assert(vim.fn.maparg('<C-A-Left>', 'n', false, true).buffer ~= 1
        and vim.fn.maparg('<C-A-Right>', 'n', false, true).buffer ~= 1,
      'tree panel 不应接管用户的 resize 快捷键')

    vim.cmd('vertical resize 40')
    assert(vim.api.nvim_win_get_width(reloaded_panel.win) == 40,
      '用户通过 Ex 命令 resize 应实际改变 panel')
    vim.api.nvim_exec_autocmds('WinResized', {})
    assert(vim.wait(500, function() return panel_state:get('width') == 40 end),
      '显式派发 WinResized 后应防抖写入共享状态')

    vim.cmd('vertical resize 43')
    vim.api.nvim_win_close(reloaded_panel.win, true)

    local directly_closed_panel = TreePanel.new({
      id = 'test-direct-close',
      state = panel_state,
      source = function() return {} end,
    })
    directly_closed_panel:open()
    assert(vim.api.nvim_win_get_width(directly_closed_panel.win) == 43,
      '绕过 panel:close 直接关窗也应保存实际宽度')
    directly_closed_panel:close()
  end)
end

T["工具栏、自绘正文与节点折叠跳转"] = function()
  child.lua_func(function()
    local target = vim.fn.tempname() .. '.lua'
    vim.fn.writefile({ 'local target = true' }, target)
    local opened
    local jumped
    local behavior_panel = TreePanel.new({
      id = 'test-behavior',
      title = 'Behavior',
      on_attach = function(current)
        TreePanel.apply_default_mappings(current)
        vim.wo[current.win].winhighlight = 'Normal:NormalFloat,CursorLine:Visual'
      end,
      source = function()
        return {
          {
            id = 'group',
            label = 'Group',
            children = {
              {
                id = 'leaf',
                label = 'local value = true',
                location = { file = target, row = 1, col = 0 },
              },
            },
          },
        }
      end,
      open = function(node) opened = node.id end,
      jump = function(node) jumped = node.id end,
      toolbar = {
        items = {
          { label = 'Open', key = '<CR>' },
          { label = 'Filter', key = '/' },
          { label = 'Copy all', key = 'C' },
          { label = 'Delete all', key = 'D' },
        },
      },
      render = {
        winbar = function()
          return {
            chunks = {
              { 'Fixed 100% ', 'Comment' },
              { 'Help', 'Title' },
            },
          }
        end,
        header = function() return { text = 'Custom header', hl = 'Title' } end,
        node = function(ctx)
          return {
            chunks = {
              { string.rep('  ', ctx.depth), 'Comment' },
              { ctx.node.label, ctx.has_children and 'Directory' or 'String' },
            },
            virt_text = not ctx.has_children and { { 'leaf', 'Comment' } } or nil,
            virt_text_pos = 'eol',
          }
        end,
        footer = function(ctx) return ('%d visible'):format(ctx.count) end,
      },
    })
    behavior_panel:open()
    assert(behavior_panel.toolbar_win and vim.api.nvim_win_is_valid(behavior_panel.toolbar_win)
        and behavior_panel.toolbar_buf and vim.api.nvim_buf_is_valid(behavior_panel.toolbar_buf),
      'toolbar 应使用独立窗口，不占用或覆盖正文 buffer')
    assert(vim.wo[behavior_panel.toolbar_win].fillchars:find('horiz: ', 1, true)
        and vim.wo[behavior_panel.toolbar_win].winhighlight:find('Normal:NormalFloat', 1, true)
        and vim.wo[behavior_panel.toolbar_win].winhighlight:find('StatusLine:NormalFloat', 1, true),
      'toolbar 应继承正文背景，且不绘制额外分割线或状态栏底色')
    vim.api.nvim_win_set_width(behavior_panel.win, 24)
    vim.api.nvim_exec_autocmds('WinResized', {})
    local toolbar_lines = vim.api.nvim_buf_get_lines(behavior_panel.toolbar_buf, 0, -1, false)
    assert(#toolbar_lines > 1
        and table.concat(toolbar_lines, '\n'):find('Open ↵', 1, true)
        and table.concat(toolbar_lines, '\n'):find('Delete all ⇧D', 1, true),
      'toolbar 宽度不足时应完整换成多行，不得删减快捷键')
    assert(vim.api.nvim_get_current_win() == behavior_panel.win,
      'toolbar resize 重排不应抢走正文焦点')
    vim.api.nvim_set_current_win(behavior_panel.toolbar_win)
    assert(vim.wait(100, function() return vim.api.nvim_get_current_win() == behavior_panel.win end),
      '点击或进入 toolbar 后应自动把焦点还给正文面板')
    local fixed_winbar = vim.wo[behavior_panel.win].winbar
    assert(fixed_winbar:find('Fixed 100%%', 1, true)
        and fixed_winbar:find('%#Comment#', 1, true)
        and fixed_winbar:find('%#Title#', 1, true),
      '调用方应能渲染固定 winbar，并安全转义 statusline 百分号')
    assert(vim.api.nvim_buf_get_lines(behavior_panel.buf, 0, -1, false)[1] == 'Custom header'
        and vim.api.nvim_buf_get_lines(behavior_panel.buf, 0, -1, false)[4] == '2 visible',
      '调用方应能完整自定义 header、node chunks 与 footer')
    local behavior_marks = vim.api.nvim_buf_get_extmarks(
      behavior_panel.buf,
      behavior_panel.ns,
      { 2, 0 },
      { 2, -1 },
      { details = true }
    )
    local has_eol_virt_text = false
    for _, mark in ipairs(behavior_marks) do
      if mark[4].virt_text and mark[4].virt_text_pos == 'eol' then
        has_eol_virt_text = true
        break
      end
    end
    assert(has_eol_virt_text,
      '自定义渲染应能选择 virt_text_pos')

    vim.api.nvim_win_set_cursor(behavior_panel.win, { 2, 0 })
    behavior_panel:execute('close_node')
    assert(vim.api.nvim_win_get_cursor(behavior_panel.win)[1] == 2,
      '收起当前节点后应保持光标节点，不得跳到顶部')
    behavior_panel:execute('open_node')
    assert(vim.api.nvim_win_get_cursor(behavior_panel.win)[1] == 2,
      '展开当前节点后应保持光标节点，不得跳到顶部')
    behavior_panel:execute('next_item')
    assert(vim.api.nvim_win_get_cursor(behavior_panel.win)[1] == 3,
      'next_item 应跳过 header 并移动到下一节点')
    vim.cmd('normal! zt')
    assert(vim.wo[behavior_panel.win].winbar == fixed_winbar,
      '滚动 tree buffer 不应带走固定 winbar')
    behavior_panel:execute('close_node')
    assert(vim.api.nvim_win_get_cursor(behavior_panel.win)[1] == 2
        and behavior_panel.folded.group == true
        and behavior_panel.rows[3] == nil,
      '叶节点按一次 h 应直接折叠父节点并聚焦父节点')
    behavior_panel:execute('open_node')
    behavior_panel:execute('next_item')
    behavior_panel:execute('prev_item')
    assert(vim.api.nvim_win_get_cursor(behavior_panel.win)[1] == 2,
      'prev_item 应在节点行之间移动')

    vim.api.nvim_win_set_cursor(behavior_panel.win, { 3, 0 })
    behavior_panel:execute('open_node')
    assert(opened == 'leaf' and behavior_panel:is_open(),
      'Enter/l 的 open_node 应进入叶节点但保留 panel')
    behavior_panel:execute('jump')
    assert(jumped == 'leaf' and not behavior_panel:is_open(),
      'gf 的 jump 应进入叶节点并关闭 panel')
    assert(not behavior_panel.toolbar_win and not behavior_panel.toolbar_buf,
      '关闭 panel 应同步释放 toolbar 窗口与 buffer')
  end)
end

T["关闭与打开回调报错仍完整回滚资源"] = function()
  child.lua_func(function()
    local original_notify = vim.notify
    local close_error
    vim.notify = function(message) close_error = message end
    local failing_close_panel = TreePanel.new({
      id = 'test-failing-close-hook',
      source = function() return {} end,
      on_close = function() error('close hook failed') end,
    })
    failing_close_panel:open()
    failing_close_panel:close()
    vim.notify = original_notify
    assert(not failing_close_panel:is_open() and failing_close_panel.buf == nil
        and close_error and close_error:find('close hook failed', 1, true),
      '关闭 hook 异常不应留下半清理的 panel 状态')

    local function assert_open_rolls_back(opts, message)
      local windows = #vim.api.nvim_list_wins()
      local failed_panel = TreePanel.new(opts)
      local opened = pcall(function() failed_panel:open() end)
      assert(not opened, message .. '应向调用方返回错误')
      assert(#vim.api.nvim_list_wins() == windows and not failed_panel:is_open(),
        message .. '不应留下窗口')
      assert(not failed_panel.buf or not vim.api.nvim_buf_is_valid(failed_panel.buf),
        message .. '不应留下 buffer')
    end

    assert_open_rolls_back({
      id = 'test-invalid-mapping',
      on_attach = function(current)
        TreePanel.apply_mappings(current, { x = 'not-an-action' })
      end,
      source = function() return {} end,
    }, '非法映射')

    assert_open_rolls_back({
      id = 'test-invalid-mapping-spec',
      on_attach = function(current)
        TreePanel.apply_mappings(current, {
          x = { action = 'close_panel', callback = function() end },
        })
      end,
      source = function() return {} end,
    }, '同时声明 action 与 callback 的映射')

    assert_open_rolls_back({
      id = 'test-source-error',
      source = function() error('source failed') end,
    }, 'source 异常')
  end)
end

T["多物理行节点导航恢复到节点首行"] = function()
  child.lua_func(function()
    local multiline_panel = TreePanel.new({
      id = 'test-multiline-rows',
      source = function()
        return {
          { id = 'multiline-a', label = 'A' },
          { id = 'multiline-b', label = 'B' },
        }
      end,
      render = {
        header = function() return { text = 'Header\nDetails' } end,
        node = function(ctx)
          return { text = ctx.node.label == 'A' and 'A\nA details' or 'B' }
        end,
        footer = function() return 'Footer\nEnd' end,
      },
    })
    multiline_panel:open()
    local multiline_lines = vim.api.nvim_buf_get_lines(multiline_panel.buf, 0, -1, false)
    assert(#multiline_lines == 7
        and multiline_lines[1] == 'Header'
        and multiline_lines[2] == 'Details'
        and multiline_lines[3] == 'A'
        and multiline_lines[4] == 'A details'
        and multiline_lines[5] == 'B'
        and multiline_lines[6] == 'Footer'
        and multiline_lines[7] == 'End',
      '树面板必须保留多行绘制结果的全部物理行')
    assert(multiline_panel.rows[3].node.id == 'multiline-a'
        and multiline_panel.rows[4].node.id == 'multiline-a'
        and multiline_panel.rows[5].node.id == 'multiline-b'
        and #multiline_panel.row_lines == 2
        and multiline_panel.row_lines[1] == 3
        and multiline_panel.row_lines[2] == 5,
      '树面板必须把物理行映射到逻辑节点且导航锚点唯一')
    vim.api.nvim_win_set_cursor(multiline_panel.win, { 1, 0 })
    multiline_panel:execute('prev_item')
    assert(vim.api.nvim_win_get_cursor(multiline_panel.win)[1] == 5,
      '从标题行向上导航必须循环到末尾节点')
    vim.api.nvim_win_set_cursor(multiline_panel.win, { 1, 0 })
    multiline_panel:execute('next_item')
    assert(vim.api.nvim_win_get_cursor(multiline_panel.win)[1] == 3,
      '从标题行向下导航必须进入首节点')
    vim.api.nvim_win_set_cursor(multiline_panel.win, { 7, 0 })
    multiline_panel:execute('prev_item')
    assert(vim.api.nvim_win_get_cursor(multiline_panel.win)[1] == 5,
      '从页脚行向上导航必须进入末尾节点')
    vim.api.nvim_win_set_cursor(multiline_panel.win, { 7, 0 })
    multiline_panel:execute('next_item')
    assert(vim.api.nvim_win_get_cursor(multiline_panel.win)[1] == 3,
      '从页脚行向下导航必须循环到首节点')
    vim.api.nvim_win_set_cursor(multiline_panel.win, { 4, 0 })
    assert(multiline_panel:_cursor_row().node.id == 'multiline-a',
      '续行仍必须激活所属逻辑节点')
    multiline_panel:execute('next_item')
    assert(vim.api.nvim_win_get_cursor(multiline_panel.win)[1] == 5,
      '从续行向下导航必须进入下一逻辑节点')
    multiline_panel:execute('prev_item')
    assert(vim.api.nvim_win_get_cursor(multiline_panel.win)[1] == 3,
      '向上导航必须在逻辑节点锚点之间移动')
    vim.api.nvim_win_set_cursor(multiline_panel.win, { 4, 0 })
    multiline_panel:refresh()
    assert(vim.api.nvim_win_get_cursor(multiline_panel.win)[1] == 3,
      '刷新必须把已选多行节点恢复到首物理行')
    multiline_panel:close()
  end)
end

T["渲染器返回 nil 隐藏节点且空树仍有状态行"] = function()
  child.lua_func(function()
    local nil_renderer_panel = TreePanel.new({
      id = 'test-nil-renderers',
      source = function()
        return {
          { id = 'hidden-by-renderer', label = 'Hidden' },
          { id = 'visible-after-nil', label = 'Visible' },
        }
      end,
      render = {
        header = function() return nil end,
        node = function(ctx)
          if ctx.node.id == 'hidden-by-renderer' then return nil end
          return ctx.node.label
        end,
        footer = function() return nil end,
      },
    })
    nil_renderer_panel:open()
    local nil_renderer_lines = vim.api.nvim_buf_get_lines(nil_renderer_panel.buf, 0, -1, false)
    assert(#nil_renderer_lines == 1 and nil_renderer_lines[1] == 'Visible',
      '返回 nil 的标题、节点和页脚渲染器不得生成空物理行')
    assert(nil_renderer_panel.rows[1].node.id == 'visible-after-nil' and nil_renderer_panel.rows[2] == nil,
      '渲染为 nil 的节点不得占据逻辑行或物理行')
    nil_renderer_panel:close()

    local nil_empty_panel = TreePanel.new({
      id = 'test-nil-empty-renderer',
      source = function() return {} end,
      render = {
        header = function() return nil end,
        empty = function() return nil end,
        footer = function() return nil end,
      },
    })
    nil_empty_panel:open()
    local nil_empty_lines = vim.api.nvim_buf_get_lines(nil_empty_panel.buf, 0, -1, false)
    assert(#nil_empty_lines == 1 and nil_empty_lines[1] == 'No items',
      '空状态渲染器返回 nil 时必须保留默认空状态')
    nil_empty_panel:close()
  end)
end

T["导航跳过展开分组且折叠后可重新进入"] = function()
  child.lua_func(function()
    local group_panel = TreePanel.new({
      id = 'test-navigable-folded',
      source = function()
        return {
          { id = 'file:a', navigable = 'folded', selectable = false, children = { { id = 'a1' }, { id = 'a2' } } },
          { id = 'file:b', navigable = 'folded', selectable = false, children = { { id = 'b1' } } },
          { id = 'never', navigable = false },
          { id = 'tail' },
        }
      end,
    })
    group_panel:open()
    local function cursor_id() return group_panel.rows[vim.api.nvim_win_get_cursor(group_panel.win)[1]].node.id end
    vim.api.nvim_win_set_cursor(group_panel.win, { 1, 0 })
    local walked = {}
    for _ = 1, 4 do
      group_panel:execute('next_item')
      walked[#walked + 1] = cursor_id()
    end
    assert(table.concat(walked, ',') == 'a1,a2,b1,tail',
      "j 应跳过展开的 'folded' 分组标题与 navigable=false 行，实际：" .. table.concat(walked, ','))
    group_panel:execute('prev_item')
    assert(cursor_id() == 'b1', 'k 同样跳过')

    vim.api.nvim_win_set_cursor(group_panel.win, { group_panel.node_lines.a2, 0 })
    group_panel:execute('close_node')
    assert(cursor_id() == 'file:a' and group_panel.folded['file:a'] == true, '子项上 h 折叠分组并停在分组行')
    group_panel:execute('next_item')
    group_panel:execute('prev_item')
    assert(cursor_id() == 'file:a', '折叠后的分组行可被 j/k 停留，否则无法再展开')
    group_panel:execute('open_node')
    assert(cursor_id() == 'a1', 'l 展开后光标进入第一个子项')
    group_panel:execute('toggle_node')
    assert(cursor_id() == 'file:a' and group_panel.folded['file:a'] == true, '子项上 Tab 折叠所属分组')
    group_panel:execute('toggle_node')
    assert(cursor_id() == 'a1', 'Tab 展开后同样进入第一个子项')
    group_panel:close()
  end)
end

return T
