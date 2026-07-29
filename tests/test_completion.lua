-- buffer-local 补全上下文、路径 descriptor 与 Blink 转换边界测试
-- 运行：nvim --headless --clean -l tests/test_completion.lua

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.runtimepath:prepend(repo)

local Completion = require('vv-utils.completion')

local passed = 0
local failed = 0

local function test(name, fn)
  local ok, error = pcall(fn)
  if ok then
    passed = passed + 1
    print('PASS: ' .. name)
  else
    failed = failed + 1
    print('FAIL: ' .. name .. ': ' .. tostring(error))
  end
end

test('attach 和 detach 只清理自己注册的 descriptor', function()
  local buf = vim.api.nvim_create_buf(false, true)
  local first = { complete = function() end }
  local second = { complete = function() end }
  local detach_first = Completion.attach(buf, first)

  assert(Completion.get(buf) == first)
  Completion.attach(buf, second)
  detach_first()
  assert(Completion.get(buf) == second)

  Completion.detach(buf)
  assert(Completion.get(buf) == nil)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test('detach 后长寿命 buffer 不保留 descriptor 闭包', function()
  local buf = vim.api.nvim_create_buf(false, true)
  local weak = setmetatable({}, { __mode = 'v' })
  local descriptor = {
    payload = string.rep('x', 1024 * 1024),
    complete = function() end,
  }
  weak[1] = descriptor

  local detach = Completion.attach(buf, descriptor)
  descriptor = nil
  detach()
  collectgarbage('collect')
  collectgarbage('collect')

  assert(weak[1] == nil, 'detached descriptor should be collectable before buffer wipe')
  assert(vim.api.nvim_buf_is_valid(buf), 'fixture buffer should remain alive')
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test('path descriptor 传递最终候选和扫描预算', function()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. '/alpha', 'p')

  local descriptor = Completion.path({
    mode = 'directory',
    cwd = function() return root end,
  })
  local result = descriptor.complete({
    bufnr = 0,
    line = 'a',
    cursor = { 1, 1 },
  }, {
    max_items = 7,
    scan_max_items = 33,
    timeout_ms = 41,
  })

  assert(type(result) == 'table')
  ---@cast result vv-utils.path_completion.Result
  assert(result.items[1].word == 'alpha/')
  vim.fn.delete(root, 'rf')
end)

test('Blink source 取消异步 descriptor 后不回写过期结果', function()
  package.loaded['blink.cmp.types'] = {
    CompletionItemKind = { File = 17, Folder = 19 },
  }

  local buf = vim.api.nvim_create_buf(false, true)
  local descriptor_cancelled = false
  Completion.attach(buf, {
    complete = function(_, _, complete)
      vim.defer_fn(function()
        complete({
          start_col = 0,
          items = { { word = 'late.lua', kind = 'File' } },
        })
      end, 20)
      return function() descriptor_cancelled = true end
    end,
  })

  local response
  local cancel = require('vv-utils.blink').new():get_completions({
    bufnr = buf,
    line = 'la',
    cursor = { 1, 2 },
  }, function(value) response = value end)
  assert(type(cancel) == 'function')
  cancel()
  vim.wait(60)

  assert(descriptor_cancelled)
  assert(response == nil, 'cancelled request must not publish stale completion items')
  Completion.detach(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  package.loaded['blink.cmp.types'] = nil
end)

test('Blink source 使用统一上限并生成精确 textEdit', function()
  package.loaded['blink.cmp.types'] = {
    CompletionItemKind = { File = 17, Folder = 19 },
  }

  local buf = vim.api.nvim_create_buf(false, true)
  Completion.attach(buf, {
    complete = function(_, defaults)
      assert(defaults.max_items == 1)
      return {
        start_col = 3,
        items = {
          { word = 'src/one/', abbr = 'one/', kind = 'Folder' },
          { word = 'src/two.lua', abbr = 'two.lua', kind = 'File' },
        },
      }
    end,
  })

  local source = require('vv-utils.blink').new({ max_items = 1 })
  local response
  source:get_completions({
    bufnr = buf,
    line = 'xx src/o',
    cursor = { 2, 8 },
  }, function(value) response = value end)

  assert(#response.items == 1)
  assert(response.items[1].kind == 19)
  assert(response.items[1].textEdit.range.start.line == 1)
  assert(response.items[1].textEdit.range.start.character == 3)
  assert(response.items[1].textEdit.range['end'].character == 8)

  Completion.detach(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  package.loaded['blink.cmp.types'] = nil
end)

test('预过滤候选保留调用方排名', function()
  package.loaded['blink.cmp.types'] = {
    CompletionItemKind = { File = 17, Folder = 19 },
  }

  local items = require('vv-utils.blink.items').convert({
    start_col = 0,
    pre_filtered = true,
    items = {
      { word = 'zzz/abc', kind = 'File', rank = 1 },
      { word = 'abc/abcx', kind = 'File', rank = 2 },
    },
  }, {
    bufnr = 0,
    line = 'abc',
    cursor = { 1, 3 },
    bounds = { start_col = 1, length = 3 },
  }, 50)

  assert(items[1].filterText == 'abc' and items[2].filterText == 'abc')
  assert(items[1].sortText < items[2].sortText)
  assert(items[1].score_offset > items[2].score_offset)
  package.loaded['blink.cmp.types'] = nil
end)

test('prompt 关闭时释放 completion descriptor', function()
  local descriptor = { complete = function() return { start_col = 0, items = {} } end }
  local handle = require('vv-utils.prompt').open(vim.api.nvim_get_current_win(), {
    completion = descriptor,
    on_change = function() end,
    on_accept = function() end,
    on_cancel = function() end,
  })
  assert(handle)

  local prompt_buf = vim.api.nvim_get_current_buf()
  assert(Completion.get(prompt_buf) == descriptor)
  handle.close()
  assert(Completion.get(prompt_buf) == nil)
end)

test('prompt 删除到空后继续 Backspace 不会越过输入行', function()
  local handle = require('vv-utils.prompt').open(vim.api.nvim_get_current_win(), {
    on_change = function() end,
    on_accept = function() end,
    on_cancel = function() end,
  })
  assert(handle)

  local prompt_buf = vim.api.nvim_get_current_buf()
  local prompt_win = vim.api.nvim_get_current_win()
  local backspace = vim.api.nvim_replace_termcodes('ia<BS><BS><Esc>', true, false, true)
  vim.api.nvim_feedkeys(backspace, 'mt', false)
  vim.wait(20)

  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(prompt_buf, 0, -1, false), { '', '' }))
  assert(vim.api.nvim_win_get_cursor(prompt_win)[1] == 2)
  handle.close()
end)

test('prompt 从任意结构删除恢复双行字段', function()
  for _, keys in ipairs({ 'dd', 'dG', 'dk' }) do
    local changes = {}
    local handle = require('vv-utils.prompt').open(vim.api.nvim_get_current_win(), {
      initial = 'query',
      debounce = 0,
      on_change = function(query) changes[#changes + 1] = query end,
      on_accept = function() end,
      on_cancel = function() end,
    })
    assert(handle)

    local prompt_buf = vim.api.nvim_get_current_buf()
    local prompt_win = vim.api.nvim_get_current_win()
    vim.cmd.stopinsert()
    vim.api.nvim_win_set_cursor(prompt_win, { 2, 0 })
    vim.cmd('normal! ' .. keys)
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = prompt_buf })
    vim.wait(20)

    assert(vim.deep_equal(vim.api.nvim_buf_get_lines(prompt_buf, 0, -1, false), { '', '' }))
    assert(vim.api.nvim_win_get_cursor(prompt_win)[1] == 2)
    assert(changes[#changes] == '', keys .. ': ' .. vim.inspect(changes))
    handle.close()
  end
end)

test('prompt 不为缺失的 icon 保留空格', function()
  local handle = require('vv-utils.prompt').open(vim.api.nvim_get_current_win(), {
    get_mode = function() return 'fuzzy' end,
    mode_display = function()
      return { icon = '', label = 'Fuzzy', hl = 'VVPromptLabel' }
    end,
    on_change = function() end,
    on_accept = function() end,
    on_cancel = function() end,
  })
  assert(handle)

  local prompt_buf = vim.api.nvim_get_current_buf()
  local namespace = vim.api.nvim_create_namespace('vv-utils-prompt')
  local marks = vim.api.nvim_buf_get_extmarks(
    prompt_buf,
    namespace,
    { 0, 0 },
    { 0, -1 },
    { details = true }
  )
  local chunks = marks[1] and marks[1][4].virt_text
  assert(chunks and chunks[2][1] == 'Fuzzy', vim.inspect(chunks))
  handle.close()
end)

print(string.format('%d PASS / %d FAIL', passed, failed))
if failed > 0 then vim.cmd('cquit 1') end
