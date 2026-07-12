local this = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
local root = vim.fn.fnamemodify(this, ':h:h')
vim.opt.runtimepath:prepend(root)
vim.cmd('filetype on')

local Fix = require('vv-utils.lsp.fix')
local Fs = require('vv-utils.fs')
local tmp = vim.fn.tempname()
local path = vim.fs.joinpath(tmp, 'fixture.tsx')
local uri = vim.uri_from_fname(path)
Fs.mkdir_p(tmp)
Fs.write_all(path, 'rounded-[8px] p-[16px]\n')
local script_path = vim.fs.joinpath(tmp, 'script')
Fs.write_all(script_path, '#!/usr/bin/env bash\necho ok\n')
assert(Fix.detect_filetype(script_path) == 'sh', 'content detection must support extensionless scripts')
local binary_path = vim.fs.joinpath(tmp, 'binary')
Fs.write_all(binary_path, 'PNG\0binary')
assert(Fix.detect_filetype(binary_path) == nil, 'binary files must skip content filetype detection')

local requests = 0
local client = {
  id = 902,
  name = 'fixture-lsp',
  initialized = true,
  config = { filetypes = { 'typescriptreact' } },
  offset_encoding = 'utf-16',
  supports_method = function() return true end,
  request_sync = function()
    requests = requests + 1
    local actions = {{
      title = 'Fix rounded',
      kind = 'quickfix',
      edit = { changes = { [uri] = {{
        range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 13 } },
        newText = 'rounded-lg',
      }} } },
    }}
    if requests >= 2 then
      actions[#actions + 1] = {
        title = 'Fix padding',
        kind = 'quickfix',
        edit = { changes = { [uri] = {{
          range = { start = { line = 0, character = 14 }, ['end'] = { line = 0, character = 22 } },
          newText = 'p-4',
        }} } },
      }
    end
    return { result = actions }
  end,
}

local original_get_clients = vim.lsp.get_clients
local original_get_configs = vim.lsp.get_configs
vim.lsp.get_configs = function() return { client.config } end
vim.lsp.get_clients = function(filter)
  if filter and filter.method and filter.method ~= 'textDocument/codeAction' then return {} end
  return { client }
end

local result = Fix.file({ path = path, timeout_ms = 2000 })
assert(result.changed and result.edits_count == 2, vim.inspect(result))
assert(Fs.read_all(path) == 'rounded-lg p-4\n')
assert(vim.fn.bufnr(path) == -1, 'temporary fix buffers must be deleted')

Fs.write_all(path, 'rounded-[8px] p-[16px]\n')
local transient_requests = 0
client.request_sync = function()
  transient_requests = transient_requests + 1
  if transient_requests == 1 then return nil, 'timeout' end
  return { result = {{
    title = 'Fix all after retry',
    kind = 'quickfix',
    edit = { changes = { [uri] = {
      {
        range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 13 } },
        newText = 'rounded-lg',
      },
      {
        range = { start = { line = 0, character = 14 }, ['end'] = { line = 0, character = 22 } },
        newText = 'p-4',
      },
    } } },
  }} }
end
local retried = Fix.file({ path = path, timeout_ms = 2000 })
assert(retried.changed and transient_requests >= 3, 'transient timeouts must retry until stable')

Fs.write_all(path, 'rounded-[8px] p-[16px]\n')
client.request_sync = function()
  return nil, { message = 'fixture request timed out' }
end
local failed = Fix.file({ path = path, timeout_ms = 1000 })
assert(failed.error.code == 'code_action_request_failed', vim.inspect(failed))
assert(Fs.read_all(path) == 'rounded-[8px] p-[16px]\n', 'failed collection must not edit disk')

vim.lsp.get_clients = original_get_clients
vim.lsp.get_configs = original_get_configs
Fs.delete(tmp)
print('vv-utils LSP fix test: ok')
