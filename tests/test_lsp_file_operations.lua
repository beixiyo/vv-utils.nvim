local this = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
local root = vim.fn.fnamemodify(this, ':h:h')
vim.opt.runtimepath:prepend(root)

local FileOperations = require('vv-utils.lsp.file_operations')
local notifications = {}
local edit = { changes = {} }
local pending_callbacks = {}
local client = {
  name = 'fixture-lsp',
  offset_encoding = 'utf-16',
  server_capabilities = { workspace = { fileOperations = {
    willRename = { filters = {} },
    didRename = { filters = {} },
  } } },
  request_sync = function(_, method, params)
    assert(method == 'workspace/willRenameFiles')
    assert(params.files[1].oldUri and params.files[1].newUri)
    return { result = edit }
  end,
  request = function(_, method, params, callback)
    assert(method == 'workspace/willRenameFiles')
    pending_callbacks[#pending_callbacks + 1] = callback
  end,
  notify = function(_, method, params)
    notifications[#notifications + 1] = { method = method, params = params }
  end,
}
local second_client = vim.deepcopy(client)
second_client.name = 'fixture-lsp-utf8'
second_client.offset_encoding = 'utf-8'
local original_get_clients = vim.lsp.get_clients
vim.lsp.get_clients = function() return { client, second_client } end

local edits, clients, error = FileOperations.will_rename_sync('/code/a.ts', '/code/b.ts', 1000)
assert(not error and #edits == 2 and clients[1] == 'fixture-lsp')

local done
FileOperations.will_rename_async('/code/a.ts', '/code/b.ts', 1000, function(result, timed_out)
  done = { edits = result, timed_out = timed_out }
end)
pending_callbacks[2](nil, edit)
pending_callbacks[1](nil, edit)
assert(vim.wait(1000, function() return done ~= nil end))
assert(#done.edits == 2 and done.timed_out == false)
assert(done.edits[1].encoding == 'utf-8')
assert(done.edits[2].encoding == 'utf-16')

FileOperations.notify_did_rename('/code/a.ts', '/code/b.ts')
assert(#notifications == 2 and notifications[1].method == 'workspace/didRenameFiles')

vim.lsp.get_clients = original_get_clients
print('vv-utils LSP file operations test: ok')
