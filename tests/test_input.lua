-- vv-utils.input 真实 buffer / extmark 集成测试
--
-- 运行方式：nvim --headless --clean -l tests/test_input.lua

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.runtimepath:prepend(repo)

local Input = require('vv-utils.input')

local passed = 0
local failed = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print('PASS: ' .. name)
  else
    failed = failed + 1
    print('FAIL: ' .. name .. ': ' .. tostring(err))
  end
end

local function details(buf, namespace, id)
  local mark = vim.api.nvim_buf_get_extmark_by_id(buf, namespace, id, { details = true })
  assert(#mark > 0, 'extmark should exist')
  return mark[3]
end

test('display_key and action_hint normalize public labels', function()
  assert(Input.display_key('<C-j>') == '^J', '<C-j> should display as ^J')
  assert(Input.action_hint('', '<CR>', '') == '<CR>', 'empty icon and label should be omitted')
  assert(Input.action_hint(nil, '<CR>', 'Open') == '<CR> Open', 'missing icon should preserve key and label')
  assert(Input.action_hint('>', '', 'Open') == nil, 'empty key should omit the action')
  assert(Input.action_hint('>', nil, 'Open') == nil, 'missing key should omit the action')
end)

test('overlay label and placeholder render on an empty input row', function()
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
  assert(label.virt_text[1][1] == ' Search', 'overlay label text should be rendered')
  assert(label.virt_text_pos == 'overlay', 'label should use overlay virtual text')
  assert(placeholder.virt_text[1][1] == 'Type a pattern', 'string placeholder should be rendered')

  vim.api.nvim_buf_delete(buf, { force = true })
end)

test('above label uses virtual lines and defaults to the input row', function()
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
  assert(mark[1] == 0, 'label_row should default to input_row')
  assert(mark[3].virt_lines[1][1][1] == ' Include', 'above label should use virtual lines')
  assert(mark[3].virt_lines_above == true, 'virtual line should render above the input')

  vim.api.nvim_buf_delete(buf, { force = true })
end)

test('render reuses ids and removes placeholder when input becomes non-empty', function()
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
  assert(second.label_id == label_id, 'label extmark id should be reused')
  assert(second.placeholder_id == placeholder_id, 'placeholder extmark id should be reused')
  assert(details(buf, namespace, label_id).virt_text[1][1] == 'Second',
    'reused label extmark should update its chunks')

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
  assert(third.placeholder_id == nil, 'non-empty input should clear the placeholder id')
  local removed = vim.api.nvim_buf_get_extmark_by_id(buf, namespace, placeholder_id, {})
  assert(#removed == 0, 'non-empty input should delete the placeholder extmark')

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
  assert(fourth.placeholder_id ~= nil, 'empty input should restore the placeholder')

  vim.api.nvim_buf_delete(buf, { force = true })
end)

print(string.format('%d PASS / %d FAIL', passed, failed))
if failed > 0 then vim.cmd.cquit() end
