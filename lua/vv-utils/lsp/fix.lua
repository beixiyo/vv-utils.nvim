---Neovim 内部的 LSP 自动修复引擎：文件识别、客户端等待、结果收敛与安全应用
local CodeActions = require('vv-utils.lsp.code_actions')
local WorkspaceEdit = require('vv-utils.lsp.workspace_edit')

local M = {}
local late_attach_grace_ms = 300
local action_quiet_ms = 600
local empty_action_quiet_ms = 300

local function loaded_buffer(path)
  local target = vim.fn.resolve(vim.fs.normalize(path))
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    if vim.api.nvim_buf_is_loaded(bufnr)
        and name ~= ''
        and vim.fn.resolve(vim.fs.normalize(name)) == target then
      return bufnr
    end
  end
end

local function delete_temporary_buffer(bufnr, path)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  if path and vim.fn.resolve(vim.api.nvim_buf_get_name(bufnr)) ~= vim.fn.resolve(path) then return end
  if vim.bo[bufnr].modified or #vim.fn.win_findbuf(bufnr) > 0 then return end
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end

function M.detect_filetype(path)
  local filetype = vim.filetype.match({ filename = path })
  if filetype then return filetype end

  local blob_ok, blob = pcall(vim.fn.readblob, path, 0, 4096)
  if not blob_ok then return nil end
  if blob:find('\0', 1, true) then return nil end
  local ok, contents = pcall(vim.fn.readfile, path, '', 100)
  if not ok then return nil end
  return vim.filetype.match({ filename = path, contents = contents })
end

function M.config_snapshot()
  return vim.lsp.get_configs({ enabled = true })
end

local function supports_filetype(config, filetype)
  return config.filetypes == nil or vim.tbl_contains(config.filetypes, filetype)
end

function M.supports_path(path, configs)
  local filetype = M.detect_filetype(path)
  if not filetype then return false end

  for _, config in ipairs(configs or M.config_snapshot()) do
    if supports_filetype(config, filetype) then return true end
  end
  for _, client in ipairs(vim.lsp.get_clients({ _uninitialized = true })) do
    if not client.config or supports_filetype(client.config, filetype) then return true end
  end
  return false
end

local function pending_clients(bufnr)
  return vim.iter(vim.lsp.get_clients({ bufnr = bufnr, _uninitialized = true }))
      :filter(function(client) return not client.initialized end)
      :map(function(client) return client.name end)
      :totable()
end

---等待目标 buffer 创建并初始化可响应指定方法的客户端
---@param bufnr integer
---@param opts {timeout_ms?: integer, method?: string, wait_all?: boolean, allow_late_attach?: boolean}
---@return vim.lsp.Client[] clients
---@return string[] pending
function M.wait_for_clients(bufnr, opts)
  opts = opts or {}
  local timeout_ms = opts.timeout_ms or 3000
  local method = opts.method or 'textDocument/codeAction'
  local function eligible_clients()
    return vim.lsp.get_clients({ bufnr = bufnr, method = method })
  end
  local started_at = vim.uv.hrtime()
  local clients = eligible_clients()
  if #clients == 0 and #pending_clients(bufnr) == 0 and opts.allow_late_attach == false then
    return clients, {}
  end
  if #clients == 0 and #pending_clients(bufnr) == 0 and opts.allow_late_attach ~= false then
    vim.wait(math.min(timeout_ms, late_attach_grace_ms), function()
      return #eligible_clients() > 0 or #pending_clients(bufnr) > 0
    end, 20)
  end

  local function settled()
    if opts.wait_all ~= false and #pending_clients(bufnr) > 0 then return false end
    clients = eligible_clients()
    return #clients > 0
  end
  local elapsed_ms = math.floor((vim.uv.hrtime() - started_at) / 1000000)
  if not settled() then vim.wait(math.max(timeout_ms - elapsed_ms, 0), settled, 20) end
  return clients, pending_clients(bufnr)
end

local function stable_value(value)
  if type(value) ~= 'table' then return value end
  if vim.islist(value) then return vim.iter(value):map(stable_value):totable() end

  local result = {}
  for _, key in ipairs(vim.tbl_keys(value)) do
    result[#result + 1] = { key, stable_value(value[key]) }
  end
  table.sort(result, function(left, right) return tostring(left[1]) < tostring(right[1]) end)
  return result
end

local function fingerprint(collected, error)
  if not collected then return 'error:' .. tostring(error and error.code) end
  return vim.fn.sha256(vim.json.encode(stable_value({
    clients = collected.clients,
    titles = collected.titles,
    changes = collected.workspace.changes,
  })))
end

local function retryable_collection_error(error)
  if not error or error.code ~= 'code_action_request_failed' then return false end
  local found = false
  for _, client_error in pairs(error.errors or {}) do
    found = true
    if client_error.retryable ~= true then return false end
  end
  return found
end

---等待 Code Action 集合收敛，并返回无副作用 WorkspaceEdit 事务
---@param opts {bufnr: integer, line?: integer, character?: integer, timeout_ms?: integer, request_timeout_ms?: integer, settle_timeout_ms?: integer, prefer_fix_all?: boolean}
---@return table? collected
---@return table? error
function M.collect(opts)
  local request_timeout_ms = opts.request_timeout_ms or opts.timeout_ms or 3000
  local settle_timeout_ms = opts.settle_timeout_ms or opts.timeout_ms or 3000
  local deadline = vim.uv.hrtime() + settle_timeout_ms * 1000000
  local previous
  local last_error

  while vim.uv.hrtime() < deadline do
    local remaining_ms = math.max(math.floor((deadline - vim.uv.hrtime()) / 1000000), 1)
    local attempt_timeout_ms = math.max(math.floor(remaining_ms / 2), 1)
    local collected, error = CodeActions.collect_document_fixes({
      bufnr = opts.bufnr,
      line = opts.line,
      character = opts.character,
      timeout_ms = math.min(request_timeout_ms, attempt_timeout_ms),
      prefer_fix_all = opts.prefer_fix_all,
    })
    if error and error.code ~= 'no_quickfixes' and error.code ~= 'no_lsp' then
      if not retryable_collection_error(error) then return nil, error end
      last_error = error
    else
      last_error = nil
      local current = fingerprint(collected, error)
      if current == previous then return collected, error end
      previous = current
    end

    remaining_ms = math.floor((deadline - vim.uv.hrtime()) / 1000000)
    if remaining_ms <= 0 then break end
    local quiet_ms = collected and action_quiet_ms or empty_action_quiet_ms
    vim.wait(math.min(quiet_ms, remaining_ms))
  end

  return nil, last_error or {
    code = 'code_actions_unstable',
    message = 'Code actions did not stabilize before the fix timeout',
  }
end

local function sync_from_disk(bufnr, path)
  if vim.bo[bufnr].modified then
    return false, { code = 'buffer_modified', message = 'Refusing to replace unsaved changes' }
  end
  local ok, error = pcall(vim.api.nvim_buf_call, bufnr, function() vim.cmd('silent checktime') end)
  if not ok then return false, { code = 'buffer_sync_failed', message = tostring(error) } end
  return true
end

---修复一个文件；同一文件的多客户端编辑作为一个 WorkspaceEdit 原子应用
---@param opts {path: string, line?: integer, character?: integer, timeout_ms?: integer, request_timeout_ms?: integer, settle_timeout_ms?: integer, save?: boolean, cleanup?: boolean, configs?: table[], cleanup_owned?: boolean, cleanup_transient?: boolean}
---@return table result
function M.file(opts)
  local path = vim.fs.normalize(vim.fn.fnamemodify(opts.path, ':p'))
  local timeout_ms = opts.timeout_ms or 3000
  local bufnr = loaded_buffer(path)
  local temporary = bufnr == nil
  local cleanup_buffer = temporary or opts.cleanup_owned == true or (opts.cleanup_transient == true
    and not vim.bo[bufnr].buflisted
    and not vim.bo[bufnr].modified
    and #vim.fn.win_findbuf(bufnr) == 0)

  if not vim.uv.fs_lstat(path) then
    return { changed = false, error = { code = 'document_not_found', message = 'Document does not exist' } }
  end
  if temporary and not M.supports_path(path, opts.configs) then
    return { changed = false, error = { code = 'no_lsp', message = 'No enabled LSP matches the filetype' } }
  end

  if temporary then
    bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
  end
  local function finish(result)
    if opts.cleanup ~= false and cleanup_buffer then
      delete_temporary_buffer(bufnr, path)
      -- apply 后仍可能到达 diagnostics 等异步回调，再做一次幂等清理覆盖该窗口
      vim.defer_fn(function() delete_temporary_buffer(bufnr, path) end, 200)
    end
    return result
  end

  local synced, sync_error = sync_from_disk(bufnr, path)
  if not synced then return finish({ changed = false, error = sync_error }) end

  local clients, pending = M.wait_for_clients(bufnr, {
    timeout_ms = timeout_ms,
    method = 'textDocument/codeAction',
    wait_all = true,
    allow_late_attach = temporary,
  })
  if #pending > 0 then
    return finish({ changed = false, error = {
      code = 'lsp_initialization_timeout',
      message = 'LSP clients did not finish initializing before the fix timeout',
      pending_clients = pending,
    } })
  end
  if #clients == 0 then
    return finish({ changed = false, error = { code = 'no_lsp', message = 'No LSP client attached' } })
  end

  local collected, error = M.collect({
    bufnr = bufnr,
    line = opts.line,
    character = opts.character,
    timeout_ms = timeout_ms,
    request_timeout_ms = opts.request_timeout_ms,
    settle_timeout_ms = opts.settle_timeout_ms,
  })
  if not collected then return finish({ changed = false, error = error }) end

  local applied, apply_error = WorkspaceEdit.apply(collected.workspace, { save = opts.save ~= false })
  if not applied then return finish({ changed = false, error = apply_error }) end
  if opts.cleanup ~= false then WorkspaceEdit.cleanup(collected.workspace) end
  local result = {
    changed = true,
    saved = opts.save ~= false,
    clients = collected.clients,
    titles = collected.titles,
    actions_count = collected.actions_count,
    files_changed = collected.workspace.files_changed,
    edits_count = collected.workspace.edits_count,
  }
  return finish(result)
end

---异步串行修复一组文件，每个文件之间让出 Neovim 事件循环
---@param paths string[]
---@param opts? table
function M.files(paths, opts)
  opts = opts or {}
  local configs = M.config_snapshot()
  local cleanup_owned = {}
  for _, path in ipairs(paths) do
    cleanup_owned[path] = loaded_buffer(path) == nil
  end
  local index = 0
  local results = {}

  local function next_file()
    index = index + 1
    if index > #paths then
      if opts.on_complete then opts.on_complete(results) end
      return
    end
    vim.schedule(function()
      local file_opts = vim.tbl_extend('force', opts, { path = paths[index], configs = configs })
      file_opts.cleanup_owned = cleanup_owned[paths[index]]
      file_opts.on_result = nil
      file_opts.on_complete = nil
      local result = M.file(file_opts)
      results[#results + 1] = { path = paths[index], result = result }
      if opts.on_result then opts.on_result(paths[index], result) end
      next_file()
    end)
  end
  next_file()
end

return M
