local this = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
local root = vim.fn.fnamemodify(this, ':h:h')
vim.opt.runtimepath:prepend(root)

local CodeActions = require('vv-utils.lsp.code_actions')
local Fs = require('vv-utils.fs')
local tmp = vim.fn.tempname()
local path = vim.fs.joinpath(tmp, 'fixture.tsx')
local uri = vim.uri_from_fname(path)
local original = 'rounded-[8px] p-[16px]'

Fs.mkdir_p(tmp)
Fs.write_all(path, original .. '\n')
local bufnr = vim.fn.bufadd(path)
vim.fn.bufload(bufnr)
local requests = {}
local client = {
  id = 901,
  name = 'fixture-lsp',
  offset_encoding = 'utf-16',
  supports_method = function() return true end,
  request_sync = function(_, _, params)
    requests[#requests + 1] = vim.deepcopy(params)
    return { result = {
      {
        title = 'Fix rounded',
        kind = 'quickfix',
        edit = { changes = { [uri] = {{
          range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 13 } },
          newText = 'rounded-lg',
        }} } },
      },
      {
        title = 'Fix padding',
        kind = 'quickfix',
        edit = { changes = { [uri] = {{
          range = { start = { line = 0, character = 14 }, ['end'] = { line = 0, character = 22 } },
          newText = 'p-4',
        }} } },
      },
    } }
  end,
}

local original_get_clients = vim.lsp.get_clients
vim.lsp.get_clients = function() return { client } end

local fixed = CodeActions.fix_document({ bufnr = bufnr })
assert(fixed.changed and fixed.saved, vim.inspect(fixed))
assert(fixed.edits_count == 2 and fixed.files_changed == 1)
assert(Fs.read_all(path) == 'rounded-lg p-4\n')

vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { original })
vim.api.nvim_buf_call(bufnr, function() vim.cmd('silent write') end)
requests = {}
local line_fixed = CodeActions.fix_document({ bufnr = bufnr, line = 1, save = false })
assert(line_fixed.changed, vim.inspect(line_fixed))
assert(line_fixed.saved == false and vim.bo[bufnr].modified)
assert(Fs.read_all(path) == original .. '\n', 'save=false must preserve the disk snapshot')
assert(vim.iter(requests):all(function(params)
  return not vim.tbl_contains(params.context.only or {}, 'source.fixAll')
end), 'line fixes must not request source.fixAll')

vim.lsp.get_clients = original_get_clients
Fs.delete(tmp)
print('vv-utils LSP code action test: ok')
