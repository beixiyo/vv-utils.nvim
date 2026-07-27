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
  request = function(_, _, params, callback)
    requests[#requests + 1] = vim.deepcopy(params)
    callback(nil, {
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
    })
    return true, #requests
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

client.request = function(_, _, _, callback)
  callback({ code = -32603, message = 'fixture response failed' })
  return true, 1
end
local failed = CodeActions.fix_document({ bufnr = bufnr, timeout_ms = 10 })
assert(failed.changed == false and failed.error.code == 'code_action_request_failed',
  'client request failures must not be reported as no_quickfixes')
assert(failed.error.errors['fixture-lsp'].message == 'fixture response failed')
assert(failed.error.errors['fixture-lsp'].kind == 'response_error')
assert(failed.error.errors['fixture-lsp'].retryable == false)

local dispatched = {}
local parallel_clients = {}
for index, name in ipairs({ 'typescript-tools', 'tailwindcss' }) do
  parallel_clients[index] = {
    id = 910 + index,
    name = name,
    offset_encoding = 'utf-16',
    supports_method = function() return true end,
    request = function(self, method, _, callback)
      assert(method == 'textDocument/codeAction')
      dispatched[#dispatched + 1] = self.name
      vim.schedule(function()
        assert(#dispatched % 2 == 0, 'all clients must be dispatched before awaiting responses')
        callback(nil, {})
      end)
      return true, self.id
    end,
  }
end
vim.lsp.get_clients = function() return parallel_clients end
local no_fixes, no_fixes_error = CodeActions.collect_document_fixes({
  bufnr = bufnr,
  timeout_ms = 100,
})
assert(not no_fixes and no_fixes_error.code == 'no_quickfixes', vim.inspect(no_fixes_error))
assert(vim.deep_equal(dispatched, {
  'typescript-tools',
  'tailwindcss',
  'typescript-tools',
  'tailwindcss',
}), 'each request phase must dispatch all eligible clients together')

local cancelled = 0
for _, pending_client in ipairs(parallel_clients) do
  pending_client.request = function(self)
    return true, self.id
  end
  pending_client.cancel_request = function()
    cancelled = cancelled + 1
  end
end
local started_at = vim.uv.hrtime()
local timed_out, timeout_failure = CodeActions.collect_document_fixes({
  bufnr = bufnr,
  timeout_ms = 100,
})
local elapsed_ms = (vim.uv.hrtime() - started_at) / 1000000
assert(not timed_out and timeout_failure.code == 'code_action_request_failed',
  vim.inspect(timeout_failure))
assert(timeout_failure.errors['typescript-tools'].kind == 'timeout')
assert(timeout_failure.errors.tailwindcss.kind == 'timeout')
assert(cancelled == 2, 'every request left at the shared deadline must be cancelled')
assert(elapsed_ms < 175, ('two clients must share one 100ms deadline, took %.1fms'):format(elapsed_ms))

vim.lsp.get_clients = original_get_clients
Fs.delete(tmp)
print('vv-utils LSP code action test: ok')
