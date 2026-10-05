-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  this = vim.fn.fnamemodify((vim.env.VV_TEST_REPO .. '/tests/test_lsp_file_operations.lua'), ':p')
  root = vim.fn.fnamemodify(this, ':h:h')
  vim.opt.runtimepath:prepend(root)

  FileOperations = require('vv-utils.lsp.file_operations')
  notifications = {}
  edit = { changes = {} }
  pending_callbacks = {}
  last_request_params = nil
  client = {
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
      last_request_params = params
      pending_callbacks[#pending_callbacks + 1] = callback
    end,
    notify = function(_, method, params)
      notifications[#notifications + 1] = { method = method, params = params }
    end,
  }
  second_client = vim.deepcopy(client)
  second_client.name = 'fixture-lsp-utf8'
  second_client.offset_encoding = 'utf-8'
  original_get_clients = vim.lsp.get_clients
  vim.lsp.get_clients = function() return { client, second_client } end
end)

T["单文件与多文件操作协议合并、等待和通知"] = function()
  child.lua_func(function()
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

    -- 多个文件必须合并进同一个请求 / 通知，而不是按文件各发一次
    local batch = {
      { old_path = '/code/a.ts', new_path = '/code/sub/a.ts' },
      { old_path = '/code/b.ts', new_path = '/code/sub/b.ts' },
    }
    pending_callbacks = {}
    local batch_done
    FileOperations.will_rename_many_async(batch, 1000, function(result, timed_out)
      batch_done = { edits = result, timed_out = timed_out }
    end)
    assert(#pending_callbacks == 2, '每个客户端只发一个请求，不得逐文件发送')
    assert(#last_request_params.files == 2, '两个文件必须合并到同一请求')
    assert(last_request_params.files[2].newUri == vim.uri_from_fname('/code/sub/b.ts'))
    pending_callbacks[1](nil, edit)
    pending_callbacks[2](nil, edit)
    assert(vim.wait(1000, function() return batch_done ~= nil end) and #batch_done.edits == 2)

    pending_callbacks = {}
    local empty_done
    FileOperations.will_rename_many_async({}, 1000, function(result, timed_out) empty_done = { result, timed_out } end)
    assert(empty_done and #empty_done[1] == 0 and empty_done[2] == false and #pending_callbacks == 0,
      '空批次不得发送任何请求')

    notifications = {}
    FileOperations.notify_did_rename_many(batch)
    assert(#notifications == 2 and #notifications[1].params.files == 2, 'didRename 必须在同一通知携带所有文件')
    notifications = {}
    FileOperations.notify_did_rename_many({})
    assert(#notifications == 0, '空批次不得发送通知')
  end)
end

return T
