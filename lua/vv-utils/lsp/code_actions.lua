---收集并安全应用文档级 LSP Code Action
local WorkspaceEdit = require('vv-utils.lsp.workspace_edit')

local M = {}

local function lsp_diagnostics(bufnr, line, namespace)
  local options = {}
  if type(line) == 'number' then options.lnum = line end
  if type(namespace) == 'number' then options.namespace = namespace end
  local diagnostics = {}
  for _, diagnostic in ipairs(vim.diagnostic.get(bufnr, options)) do
    if diagnostic.user_data and diagnostic.user_data.lsp then
      diagnostics[#diagnostics + 1] = diagnostic.user_data.lsp
    end
  end
  return diagnostics
end

local function client_diagnostics(bufnr, client, line)
  local diagnostics = {}
  local seen = {}
  local marker = ('lsp.%s.%d'):format(client.name, client.id)
  local namespaces = { [vim.lsp.diagnostic.get_namespace(client.id)] = true }
  for name, namespace in pairs(vim.api.nvim_get_namespaces()) do
    if name:find(marker, 1, true) then namespaces[namespace] = true end
  end
  for namespace in pairs(namespaces) do
    local options = { namespace = namespace }
    if type(line) == 'number' then options.lnum = line end
    for _, diagnostic in ipairs(vim.diagnostic.get(bufnr, options)) do
      local lsp_diagnostic = diagnostic.user_data and diagnostic.user_data.lsp
      if lsp_diagnostic then
        local fingerprint = vim.fn.sha256(vim.json.encode(lsp_diagnostic))
        if not seen[fingerprint] then
          seen[fingerprint] = true
          diagnostics[#diagnostics + 1] = diagnostic
        end
      end
    end
  end
  return diagnostics
end

local function diagnostic_params(bufnr, diagnostic)
  local lsp_diagnostic = diagnostic.user_data and diagnostic.user_data.lsp
  local range = lsp_diagnostic and lsp_diagnostic.range or {
    start = { line = diagnostic.lnum, character = diagnostic.col },
    ['end'] = {
      line = diagnostic.end_lnum or diagnostic.lnum,
      character = diagnostic.end_col or diagnostic.col,
    },
  }
  return {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    range = range,
    context = {
      diagnostics = lsp_diagnostic and { lsp_diagnostic } or {},
      only = { 'quickfix' },
    },
  }
end

local function request_params(bufnr, line, character, whole_file)
  local last_line = math.max(vim.api.nvim_buf_line_count(bufnr) - 1, 0)
  local position = { line = line or 0, character = character or 0 }
  return {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    range = whole_file and {
      start = { line = 0, character = 0 },
      ['end'] = { line = last_line, character = 0 },
    } or { start = position, ['end'] = position },
    context = {
      diagnostics = lsp_diagnostics(bufnr, whole_file and nil or position.line),
      only = { 'quickfix' },
    },
  }
end

local function fix_all_params(bufnr)
  local params = request_params(bufnr, nil, nil, true)
  params.context.only = { 'source.fixAll' }
  return params
end

local function request_error(response)
  if response and response.err then
    return {
      kind = 'response_error',
      code = response.err.code,
      message = response.err.message or vim.inspect(response.err),
      retryable = false,
    }
  end
end

local function remaining_ms(deadline)
  return math.max(math.floor((deadline - vim.uv.hrtime()) / 1000000), 0)
end

local function timeout_error()
  return {
    kind = 'timeout',
    message = 'LSP request did not finish before the shared deadline',
    retryable = true,
  }
end

---并行发送一批只读 LSP 请求，并让整批共享同一个绝对截止时间
---@param requests {client: vim.lsp.Client, params: table}[]
---@param method string
---@param bufnr integer
---@param deadline integer
---@return table<integer, {result?: any, error?: table}>
local function request_batch(requests, method, bufnr, deadline)
  local responses = {}
  local pending = {}

  for index, item in ipairs(requests) do
    local completed = false
    local ok, accepted, request_id = pcall(function()
      return item.client:request(method, item.params, function(error, result)
        if completed then return end
        completed = true
        pending[index] = nil
        local response = { result = result, err = error }
        responses[index] = {
          result = result,
          error = request_error(response),
        }
      end, bufnr)
    end)

    if not ok or accepted == false then
      completed = true
      responses[index] = {
        error = {
          kind = 'request_error',
          message = ok and 'LSP client rejected the request' or tostring(accepted),
          retryable = false,
        },
      }
    elseif not completed then
      pending[index] = {
        client = item.client,
        request_id = request_id,
        complete = function() completed = true end,
      }
    end
  end

  local wait_ms = remaining_ms(deadline)
  if next(pending) and wait_ms > 0 then
    vim.wait(wait_ms, function() return next(pending) == nil end, 10)
  end

  for index, request in pairs(pending) do
    request.complete()
    if request.request_id and request.client.cancel_request then
      pcall(function() request.client:cancel_request(request.request_id) end)
    end
    responses[index] = { error = timeout_error() }
  end

  return responses
end

---收集文档或指定行的所有可编辑修复，并生成安全 WorkspaceEdit 事务
---@param opts? { bufnr?: integer, line?: integer, character?: integer, timeout_ms?: integer, prefer_fix_all?: boolean, on_conflict?: 'error' | 'skip' }
---@return table? result
---@return table? error
function M.collect_document_fixes(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local timeout_ms = opts.timeout_ms or 3000
  local deadline = vim.uv.hrtime() + timeout_ms * 1000000
  local target_line = type(opts.line) == 'number' and opts.line - 1 or nil
  local target_character = type(opts.character) == 'number' and opts.character - 1 or 0
  local prefer_fix_all = opts.prefer_fix_all ~= false and target_line == nil
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = 'textDocument/codeAction' })
  if #clients == 0 then
    return nil, { code = 'no_lsp', message = 'No LSP client attached to buffer' }
  end

  local edits = {}
  local titles = {}
  local client_names = {}
  local errors = {}
  local seen = {}

  local function accept_action(action, client)
    if action.disabled or action.command or not action.edit then return false end
    local fingerprint = vim.fn.sha256(vim.json.encode({ client = client.id, edit = action.edit }))
    if seen[fingerprint] then return false end

    seen[fingerprint] = true
    edits[#edits + 1] = {
      edit = action.edit,
      encoding = client.offset_encoding or 'utf-16',
    }
    titles[#titles + 1] = action.title or 'Untitled action'
    client_names[client.name] = true
    return true
  end

  local function collect_batch(requests)
    if #requests == 0 then return {} end

    local counts = {}
    local unresolved = {}
    local responses = request_batch(requests, 'textDocument/codeAction', bufnr, deadline)
    for index, item in ipairs(requests) do
      local response = responses[index]
      if response.error then
        errors[item.client.name] = response.error
      else
        for _, action in ipairs(response.result or {}) do
          if not action.disabled
              and not action.edit
              and action.data
              and item.client:supports_method('codeAction/resolve', bufnr) then
            unresolved[#unresolved + 1] = {
              client = item.client,
              params = action,
            }
          elseif accept_action(action, item.client) then
            counts[item.client.id] = (counts[item.client.id] or 0) + 1
          end
        end
      end
    end

    local resolved = request_batch(unresolved, 'codeAction/resolve', bufnr, deadline)
    for index, item in ipairs(unresolved) do
      local response = resolved[index]
      if response.error then
        errors[item.client.name] = response.error
      elseif accept_action(response.result or item.params, item.client) then
        counts[item.client.id] = (counts[item.client.id] or 0) + 1
      end
    end

    return counts
  end

  local fix_all_requests = {}
  if prefer_fix_all then
    for _, client in ipairs(clients) do
      fix_all_requests[#fix_all_requests + 1] = {
        client = client,
        params = fix_all_params(bufnr),
      }
    end
  end
  local fix_all_counts = collect_batch(fix_all_requests)

  local fallback_clients = {}
  for _, client in ipairs(clients) do
    if not errors[client.name] and (fix_all_counts[client.id] or 0) == 0 then
      fallback_clients[#fallback_clients + 1] = client
    end
  end

  local quickfix_requests = {}
  for _, client in ipairs(fallback_clients) do
    quickfix_requests[#quickfix_requests + 1] = {
      client = client,
      params = request_params(bufnr, target_line, target_character, target_line == nil),
    }
  end
  collect_batch(quickfix_requests)

  local diagnostic_requests = {}
  for _, client in ipairs(fallback_clients) do
    if not errors[client.name] then
      for _, diagnostic in ipairs(client_diagnostics(bufnr, client, target_line)) do
        diagnostic_requests[#diagnostic_requests + 1] = {
          client = client,
          params = diagnostic_params(bufnr, diagnostic),
        }
      end
    end
  end
  collect_batch(diagnostic_requests)

  if not vim.tbl_isempty(errors) then
    return nil, {
      code = 'code_action_request_failed',
      message = 'One or more LSP clients failed while collecting code actions',
      errors = errors,
    }
  end

  if #edits == 0 then
    return nil, { code = 'no_quickfixes', message = 'No editable quickfix actions found' }
  end
  local workspace, error = WorkspaceEdit.prepare(edits, { on_conflict = opts.on_conflict })
  if not workspace then return nil, error end
  local names = vim.tbl_keys(client_names)
  table.sort(names)
  return {
    workspace = workspace,
    clients = names,
    titles = titles,
    actions_count = #titles,
  }
end

---收集、原子应用并保存文档修复
---@param opts? { bufnr?: integer, line?: integer, character?: integer, timeout_ms?: integer, prefer_fix_all?: boolean, save?: boolean, on_conflict?: 'error' | 'skip' }
---@return table result
function M.fix_document(opts)
  local collected, error = M.collect_document_fixes(opts)
  if not collected then return { changed = false, error = error } end
  local save = opts == nil or opts.save ~= false
  local applied, apply_error = WorkspaceEdit.apply(collected.workspace, { save = save })
  if not applied then return { changed = false, error = apply_error } end
  return {
    changed = true,
    saved = save,
    clients = collected.clients,
    titles = collected.titles,
    actions_count = collected.actions_count,
    files_changed = collected.workspace.files_changed,
    edits_count = collected.workspace.edits_count,
    skipped_count = collected.workspace.skipped_count,
    skipped = collected.workspace.skipped,
  }
end

return M
