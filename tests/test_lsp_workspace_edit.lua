local this = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
local root = vim.fn.fnamemodify(this, ':h:h')
vim.opt.runtimepath:prepend(root)

local Fs = require('vv-utils.fs')
local WorkspaceEdit = require('vv-utils.lsp.workspace_edit')
local tmp = vim.fn.tempname()
local path = vim.fs.joinpath(tmp, 'fixture.ts')
local uri = vim.uri_from_fname(path)

Fs.mkdir_p(tmp)
Fs.write_all(path, 'alpha beta\n')
local bufnr = vim.fn.bufadd(path)
vim.fn.bufload(bufnr)

local transaction, error = WorkspaceEdit.prepare({{
  encoding = 'utf-16',
  edit = { changes = { [uri] = {
    {
      range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 5 } },
      newText = 'one',
    },
    {
      range = { start = { line = 0, character = 6 }, ['end'] = { line = 0, character = 10 } },
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

Fs.delete(tmp)
print('vv-utils LSP workspace edit test: ok')
