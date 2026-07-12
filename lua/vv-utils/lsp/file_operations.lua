---LSP workspace 文件重命名协议原语
local M = {}

local function supports(client, capability)
  return vim.tbl_get(client, 'server_capabilities', 'workspace', 'fileOperations', capability) ~= nil
end

---构造 workspace/didRenameFiles 与 workspace/willRenameFiles 参数
---@param old_path string
---@param new_path string
---@return table params
function M.rename_params(old_path, new_path)
  return {
    files = {{
      oldUri = vim.uri_from_fname(old_path),
      newUri = vim.uri_from_fname(new_path),
    }},
  }
end

---@param capability 'willRename'|'didRename'
---@return vim.lsp.Client[] clients
function M.clients(capability)
  return vim.tbl_filter(function(client) return supports(client, capability) end, vim.lsp.get_clients())
end

---同步收集所有 workspace/willRenameFiles 响应，不应用编辑
---@param old_path string
---@param new_path string
---@param timeout_ms integer
---@return { edit: table, encoding: string }[]? edits
---@return string[]? clients
---@return table? error
function M.will_rename_sync(old_path, new_path, timeout_ms)
  local edits = {}
  local names = {}
  local params = M.rename_params(old_path, new_path)
  for _, client in ipairs(M.clients('willRename')) do
    local response, request_error = client:request_sync('workspace/willRenameFiles', params, timeout_ms)
    if request_error then
      return nil, nil, {
        code = 'resource_rename_lsp_failed',
        message = client.name .. ': ' .. tostring(request_error),
      }
    end
    names[#names + 1] = client.name
    if response and response.result then
      edits[#edits + 1] = {
        edit = response.result,
        encoding = client.offset_encoding or 'utf-16',
      }
    end
  end
  table.sort(names)
  return edits, names
end

---异步收集 workspace/willRenameFiles 响应，不应用编辑
---@param old_path string
---@param new_path string
---@param timeout_ms integer
---@param on_done fun(edits: { edit: table, encoding: string }[], timed_out: boolean)
function M.will_rename_async(old_path, new_path, timeout_ms, on_done)
  local clients = M.clients('willRename')
  if #clients == 0 then return on_done({}, false) end

  local edits = {}
  local pending = #clients
  local settled = false
  local timer = vim.uv.new_timer()

  local function finish(timed_out)
    if settled then return end
    settled = true
    timer:stop()
    pcall(function() timer:close() end)
    on_done(edits, timed_out)
  end

  timer:start(timeout_ms, 0, vim.schedule_wrap(function() finish(true) end))
  local params = M.rename_params(old_path, new_path)
  for _, client in ipairs(clients) do
    local current_client = client
    current_client:request('workspace/willRenameFiles', params, function(error, result)
      if settled then return end
      if not error and result then
        edits[#edits + 1] = {
          edit = result,
          encoding = current_client.offset_encoding or 'utf-16',
        }
      end
      pending = pending - 1
      if pending == 0 then finish(false) end
    end)
  end
end

---向支持的客户端发送 workspace/didRenameFiles
---@param old_path string
---@param new_path string
function M.notify_did_rename(old_path, new_path)
  local params = M.rename_params(old_path, new_path)
  for _, client in ipairs(M.clients('didRename')) do
    client:notify('workspace/didRenameFiles', params)
  end
end

return M
