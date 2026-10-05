-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  repo = vim.fn.fnamemodify((vim.env.VV_TEST_REPO .. '/tests/test_input.lua'), ':p:h:h')
  vim.opt.runtimepath:prepend(repo)
  Input = require('vv-utils.input')
  function details(buf, namespace, id)
    local mark = vim.api.nvim_buf_get_extmark_by_id(buf, namespace, id, { details = true })
    assert(#mark > 0, '必须存在 extmark')
    return mark[3]
  end
end)

T["动作提示省略空元素且必须有按键"] = function()
  child.lua_func(function()
    assert(Input.action_hint('', '<CR>', '') == '<CR>', '空图标与标签必须省略')
      assert(Input.action_hint(nil, '<CR>', 'Open') == '<CR> Open', '缺失图标仍必须保留按键与标签')
      assert(Input.action_hint('>', '', 'Open') == nil, '空按键必须省略整个动作')
      assert(Input.action_hint('>', nil, 'Open') == nil, '缺失按键必须省略整个动作')
  end)
end

T["空输入行绘制覆盖标签与占位提示"] = function()
  child.lua_func(function()
    local buf = vim.api.nvim_create_buf(false, true)
      local namespace = vim.api.nvim_create_namespace('vv-utils-input-test-overlay')
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '', '' })

      local ids = Input.render({
        buf = buf,
        namespace = namespace,
        input_row = 1,
        label_row = 0,
        label_chunks = { { ' Search', 'Title' } },
        placeholder = 'Type a pattern',
      })

      local label = details(buf, namespace, assert(ids.label_id))
      local placeholder = details(buf, namespace, assert(ids.placeholder_id))
      assert(label.virt_text[1][1] == ' Search', '必须绘制 overlay 标签文本')
      assert(label.virt_text_pos == 'overlay', '标签必须使用 overlay 虚拟文本')
      assert(placeholder.virt_text[1][1] == 'Type a pattern', '必须绘制字符串占位提示')

      vim.api.nvim_buf_delete(buf, { force = true })
  end)
end

T["上方标签使用虚拟行并默认锚定输入行"] = function()
  child.lua_func(function()
    local buf = vim.api.nvim_create_buf(false, true)
      local namespace = vim.api.nvim_create_namespace('vv-utils-input-test-above')
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '' })

      local ids = Input.render({
        buf = buf,
        namespace = namespace,
        input_row = 0,
        label_position = 'above',
        label_chunks = { { ' Include', 'Title' } },
      })

      local mark = vim.api.nvim_buf_get_extmark_by_id(
        buf,
        namespace,
        assert(ids.label_id),
        { details = true }
      )
      assert(mark[1] == 0, 'label_row 默认必须取 input_row')
      assert(mark[3].virt_lines[1][1][1] == ' Include', '上方标签必须使用虚拟行')
      assert(mark[3].virt_lines_above == true, '虚拟行必须显示在输入行上方')

      vim.api.nvim_buf_delete(buf, { force = true })
  end)
end

T["重绘复用标记且非空输入清除占位提示"] = function()
  child.lua_func(function()
    local buf = vim.api.nvim_create_buf(false, true)
      local namespace = vim.api.nvim_create_namespace('vv-utils-input-test-update')
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '' })

      local first = Input.render({
        buf = buf,
        namespace = namespace,
        input_row = 0,
        label_chunks = { { 'First' } },
        placeholder = { { 'Empty', 'Comment' } },
      })
      local label_id = assert(first.label_id)
      local placeholder_id = assert(first.placeholder_id)

      local second = Input.render({
        buf = buf,
        namespace = namespace,
        input_row = 0,
        label_chunks = { { 'Second' } },
        placeholder = { { 'Empty', 'Comment' } },
        label_id = label_id,
        placeholder_id = placeholder_id,
      })
      assert(second.label_id == label_id, '标签 extmark 编号必须复用')
      assert(second.placeholder_id == placeholder_id, '占位提示 extmark 编号必须复用')
      assert(details(buf, namespace, label_id).virt_text[1][1] == 'Second',
        '复用的标签 extmark 必须更新文本块')

      vim.api.nvim_buf_set_lines(buf, 0, 1, false, { 'query' })
      local third = Input.render({
        buf = buf,
        namespace = namespace,
        input_row = 0,
        label_chunks = { { 'Second' } },
        placeholder = { { 'Empty', 'Comment' } },
        label_id = second.label_id,
        placeholder_id = second.placeholder_id,
      })
      assert(third.placeholder_id == nil, '非空输入必须清除占位提示编号')
      local removed = vim.api.nvim_buf_get_extmark_by_id(buf, namespace, placeholder_id, {})
      assert(#removed == 0, '非空输入必须删除占位提示 extmark')

      vim.api.nvim_buf_set_lines(buf, 0, 1, false, { '' })
      local fourth = Input.render({
        buf = buf,
        namespace = namespace,
        input_row = 0,
        label_chunks = { { 'Second' } },
        placeholder = { { 'Empty', 'Comment' } },
        label_id = third.label_id,
        placeholder_id = third.placeholder_id,
      })
      assert(fourth.placeholder_id ~= nil, '清空输入必须恢复占位提示')

      vim.api.nvim_buf_delete(buf, { force = true })
  end)
end

return T
