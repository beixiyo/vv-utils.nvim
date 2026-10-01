---LSP workspace 文件重命名协议原语
local M = {}

local function supports(client, capability)
  return vim.tbl_get(client, 'server_capabilities', 'workspace', 'fileOperations', capability) ~= nil
end

---@class VVLspFileRename
---@field old_path string
---@field new_path string

---构造包含多个文件的 workspace/didRenameFiles 与 workspace/willRenameFiles 参数
---@param renames VVLspFileRename[]
---@return table params
function M.renames_params(renames)
  local files = {}
  for _, rename in ipairs(renames) do
    files[#files + 1] = {
      oldUri = vim.uri_from_fname(rename.old_path),
      newUri = vim.uri_from_fname(rename.new_path),
    }
  end
  return { files = files }
end

---构造单个文件的 workspace/didRenameFiles 与 workspace/willRenameFiles 参数
---@param old_path string
---@param new_path string
---@return table params
function M.rename_params(old_path, new_path)
  return M.renames_params({ { old_path = old_path, new_path = new_path } })
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
  M.will_rename_many_async({ { old_path = old_path, new_path = new_path } }, timeout_ms, on_done)
end

---异步收集一次包含多个文件的 workspace/willRenameFiles 响应，不应用编辑
---
---多个文件放进同一个请求，服务端返回一份互相一致的编辑，且总等待时间只受 timeout_ms 约束
---@param renames VVLspFileRename[]
---@param timeout_ms integer
---@param on_done fun(edits: { edit: table, encoding: string }[], timed_out: boolean)
function M.will_rename_many_async(renames, timeout_ms, on_done)
  local clients = M.clients('willRename')
  -- 没有要询问的文件时不发请求，与 notify_did_rename_many 对空数组的处理一致
  if #clients == 0 or #renames == 0 then return on_done({}, false) end

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
  local params = M.renames_params(renames)
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
  M.notify_did_rename_many({ { old_path = old_path, new_path = new_path } })
end

---向支持的客户端一次发送包含多个文件的 workspace/didRenameFiles
---@param renames VVLspFileRename[]
function M.notify_did_rename_many(renames)
  if #renames == 0 then return end
  local params = M.renames_params(renames)
  for _, client in ipairs(M.clients('didRename')) do
    client:notify('workspace/didRenameFiles', params)
  end
end

return M
