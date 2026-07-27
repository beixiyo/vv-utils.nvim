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
  config = { filetypes = { 'typescriptreact' }, cmd = { vim.v.progpath } },
  offset_encoding = 'utf-16',
  supports_method = function() return true end,
  request = function(_, _, _, callback)
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
    callback(nil, actions)
    return true, requests
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
client.request = function(_, _, _, callback)
  transient_requests = transient_requests + 1
  if transient_requests == 1 then return true, transient_requests end
  callback(nil, {{
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
  }})
  return true, transient_requests
end
local retried = Fix.file({ path = path, timeout_ms = 2000 })
assert(retried.changed and transient_requests >= 3, 'transient timeouts must retry until stable')

Fs.write_all(path, 'rounded-[8px] p-[16px]\n')
client.request = function()
  return true, 1
end
local failed = Fix.file({ path = path, timeout_ms = 1000 })
assert(failed.error.code == 'code_action_request_failed', vim.inspect(failed))
assert(Fs.read_all(path) == 'rounded-[8px] p-[16px]\n', 'failed collection must not edit disk')

vim.lsp.get_clients = function() return {} end
local no_config, no_config_error = Fix.check_path_support(path, {})
assert(not no_config and no_config_error.code == 'no_lsp_config', vim.inspect(no_config_error))

local unavailable = 'vv-utils-language-server-that-does-not-exist'
local executable, executable_error = Fix.check_path_support(path, {{
  filetypes = { 'typescriptreact' },
  cmd = { unavailable, '--stdio' },
}})
assert(not executable and executable_error.code == 'lsp_executable_missing',
  vim.inspect(executable_error))
assert(vim.deep_equal(executable_error.executables, { unavailable }))

local missing_started_at = vim.uv.hrtime()
local missing_result = Fix.file({
  path = path,
  configs = {{
    filetypes = { 'typescriptreact' },
    cmd = { unavailable, '--stdio' },
  }},
  timeout_ms = 1000,
})
local missing_elapsed_ms = (vim.uv.hrtime() - missing_started_at) / 1000000
assert(missing_result.error.code == 'lsp_executable_missing', vim.inspect(missing_result))
assert(missing_elapsed_ms < 100,
  ('missing executables must fail before waiting for LSP attachment, took %.1fms'):format(
    missing_elapsed_ms
  ))
assert(vim.fn.bufnr(path) == -1, 'an unavailable LSP must not create a temporary buffer')

local custom_transport = Fix.check_path_support(path, {{
  filetypes = { 'typescriptreact' },
  cmd = function() end,
}})
assert(custom_transport, 'function commands cannot be rejected by a static executable precheck')

local mixed_configs = Fix.check_path_support(path, {
  {
    filetypes = { 'typescriptreact' },
    cmd = { unavailable },
  },
  {
    filetypes = { 'typescriptreact' },
    cmd = { vim.v.progpath, '--headless' },
  },
})
assert(mixed_configs, 'one available matching config is enough to support the path')

vim.lsp.get_clients = original_get_clients
vim.lsp.get_configs = original_get_configs
Fs.delete(tmp)
print('vv-utils LSP fix test: ok')
