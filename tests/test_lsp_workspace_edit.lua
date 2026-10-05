-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  this = vim.fn.fnamemodify((vim.env.VV_TEST_REPO .. '/tests/test_lsp_workspace_edit.lua'), ':p')
  root = vim.fn.fnamemodify(this, ':h:h')
  vim.opt.runtimepath:prepend(root)

  Fs = require('vv-utils.fs')
  WorkspaceEdit = require('vv-utils.lsp.workspace_edit')
  tmp = vim.fn.tempname()
  path = vim.fs.joinpath(tmp, 'fixture.ts')
  uri = vim.uri_from_fname(path)

  Fs.mkdir_p(tmp)
  Fs.write_all(path, '甲😀乙 beta\n')
  bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)
end)

T["UTF-16 编辑、事务撤回与冲突跳过"] = function()
  child.lua_func(function()
    local transaction, error = WorkspaceEdit.prepare({{
      encoding = 'utf-16',
      edit = { changes = { [uri] = {
        {
          range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 4 } },
          newText = 'one',
        },
        {
          range = { start = { line = 0, character = 5 }, ['end'] = { line = 0, character = 9 } },
          newText = 'two',
        },
      } } },
    }})
    assert(transaction and not error, vim.inspect(error))
    assert(transaction.edits_count == 2 and transaction.files_changed == 1)
    local applied, apply_error = WorkspaceEdit.apply(transaction)
    assert(applied, vim.inspect(apply_error))
    assert(Fs.read_all(path) == 'one two\n')

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'alpha beta' })
    vim.api.nvim_buf_call(bufnr, function() vim.cmd('silent write') end)
    local conflict, conflict_error = WorkspaceEdit.prepare({{
      encoding = 'utf-16',
      edit = { changes = { [uri] = {
        {
          range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 5 } },
          newText = 'one',
        },
        {
          range = { start = { line = 0, character = 3 }, ['end'] = { line = 0, character = 7 } },
          newText = 'two',
        },
      } } },
    }})
    assert(not conflict and conflict_error.code == 'workspace_edit_conflict')

    -- on_conflict = 'skip'：保留先到先得的编辑，重叠候选被跳过而非整体失败
    local skipping, skip_error = WorkspaceEdit.prepare({{
      encoding = 'utf-16',
      edit = { changes = { [uri] = {
        {
          range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 5 } },
          newText = 'one',
        },
        {
          range = { start = { line = 0, character = 3 }, ['end'] = { line = 0, character = 7 } },
          newText = 'two',
        },
        {
          range = { start = { line = 0, character = 6 }, ['end'] = { line = 0, character = 10 } },
          newText = 'three',
        },
      } } },
    }}, { on_conflict = 'skip' })
    assert(skipping and not skip_error, vim.inspect(skip_error))
    assert(skipping.edits_count == 2 and skipping.skipped_count == 1, vim.inspect(skipping))
    local skip_applied, skip_apply_error = WorkspaceEdit.apply(skipping)
    assert(skip_applied, vim.inspect(skip_apply_error))
    assert(Fs.read_all(path) == 'one three\n', vim.inspect(Fs.read_all(path)))
  end)
end

return T
