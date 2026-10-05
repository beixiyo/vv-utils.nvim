-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  this = vim.fn.fnamemodify((vim.env.VV_TEST_REPO .. '/tests/test_modal.lua'), ':p')
  plugin_root = vim.fn.fnamemodify(this, ':h:h')
  package.path = table.concat({
    plugin_root .. '/lua/?.lua',
    plugin_root .. '/lua/?/init.lua',
    package.path,
  }, ';')

  Modal = require('vv-utils.modal')
end)

T["正文语义高亮与选择动作关闭窗口"] = function()
  child.lua_func(function()
    local selected
    local handle = Modal.open({
      title = 'Paste Conflict',
      body = {
        { chunks = { { 'Source ', 'Comment' }, { 'project', 'Directory' } } },
        { text = 'The destination already exists.', hl = 'DiagnosticWarn' },
      },
      actions = {
        { id = 'overwrite', label = 'Overwrite', keys = { '1', '<C-1>' }, hl = 'DiagnosticError' },
        { id = 'increment', label = 'Keep Both', keys = { '2', '<C-2>' }, hl = 'DiagnosticOk' },
      },
      cancel = { label = 'Cancel', keys = { 'q', '<Esc>' } },
      on_select = function(id) selected = id end,
    })

    local window = vim.api.nvim_get_current_win()
    local buffer = vim.api.nvim_win_get_buf(window)
    assert(handle.is_open(), 'Modal handle 必须报告窗口已打开')
    assert(vim.bo[buffer].filetype == 'vv-modal', 'Modal 必须使用默认 filetype')
    local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
    assert(lines[1] == '  Source project' and table.concat(lines, '\n'):find('Overwrite', 1, true),
      'Modal 必须绘制正文块与有序动作页脚')
    local marks = vim.api.nvim_buf_get_extmarks(buffer, -1, 0, -1, { details = true })
    local found_directory = false
    for _, mark in ipairs(marks) do
      if mark[4].hl_group == 'Directory' then found_directory = true end
    end
    assert(found_directory, 'Modal 正文块必须有语义高亮')

    vim.api.nvim_feedkeys('1', 'xt', false)
    assert(selected == 'overwrite' and not handle.is_open() and not vim.api.nvim_win_is_valid(window),
      '选择动作必须先关闭窗口再调用回调')
    handle.close()
  end)
end

T["动态正文上下文、取消与冲突键拒绝"] = function()
  child.lua_func(function()
    local rendered_context
    local cancelled = false
    handle = Modal.open({
      title = 'Render callback',
      context = { value = 'generated' },
      render = function(ctx)
        rendered_context = ctx
        return { { text = ctx.value, hl = 'String' } }
      end,
      actions = { { id = 'ok', label = 'OK', keys = 'o' } },
      on_cancel = function() cancelled = true end,
    })
    assert(rendered_context.value == 'generated', '绘制回调必须收到显式上下文')
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'xt', false)
    assert(cancelled and not handle.is_open(), '取消必须关闭窗口并调用 on_cancel')

    local ok, err = pcall(Modal.open, {
      title = 'Conflict',
      actions = {
        { id = 'a', label = 'A', keys = 'x' },
        { id = 'b', label = 'B', keys = 'x' },
      },
    })
    assert(not ok and tostring(err):find('assigned to both', 1, true), '冲突动作按键必须被拒绝')
  end)
end

T["多行 chunks 与虚拟文字渲染且主动关闭不取消"] = function()
  child.lua_func(function()
    local multiline_cancelled = 0
    handle = Modal.open({
      title = 'Multiline rows',
      body = {
        { chunks = { { 'first\nsecond', 'DiagnosticError' }, { ' tail', 'String' } } },
        { virt_text = { { ' [status]', 'Comment' } }, virt_text_pos = 'eol' },
      },
      actions = { { id = 'ok', label = 'OK', keys = 'o' } },
      on_cancel = function() multiline_cancelled = multiline_cancelled + 1 end,
    })
    window = vim.api.nvim_get_current_win()
    buffer = vim.api.nvim_win_get_buf(window)
    lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
    assert(lines[1] == '  first' and lines[2] == '  second tail',
      '含换行的文本块必须展开为缩进物理行')
    assert(lines[3] == '', '仅有 virt_text 的行必须保留空物理行')
    marks = vim.api.nvim_buf_get_extmarks(buffer, -1, 0, -1, { details = true })
    local first_error, second_error, tail_string, status_virtual = false, false, false, false
    for _, mark in ipairs(marks) do
      local details = mark[4]
      if details.hl_group == 'DiagnosticError' and mark[3] == 2 then first_error = true end
      if details.hl_group == 'DiagnosticError' and mark[3] == 2 and mark[2] == 1 then second_error = true end
      if details.hl_group == 'String' and mark[3] == 8 and mark[2] == 1 then tail_string = true end
      if details.virt_text and details.virt_text[1][1] == ' [status]' and mark[2] == 2 then
        status_virtual = true
      end
    end
    assert(first_error and second_error and tail_string and status_virtual,
      '展开后的行必须保留文本块高亮与虚拟文本')
    handle.close()
    assert(multiline_cancelled == 0, 'handle.close 不得调用 on_cancel')
  end)
end

T["外部关闭调用取消且重复关闭无副作用"] = function()
  child.lua_func(function()
    local externally_cancelled = 0
    handle = Modal.open({
      title = 'External close',
      actions = { { id = 'ok', label = 'OK', keys = 'o' } },
      on_cancel = function() externally_cancelled = externally_cancelled + 1 end,
    })
    vim.cmd('close')
    assert(not handle.is_open() and externally_cancelled == 1,
      '外部关闭窗口必须恰好调用一次 on_cancel')
    handle.close()
    assert(externally_cancelled == 1, '外部关闭后再次关闭不得重复回调')
  end)
end

return T
