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

local function resolve_action(action, client, bufnr, timeout_ms)
  if action.disabled then return nil end
  if not action.edit and action.data and client:supports_method('codeAction/resolve', bufnr) then
    local response = client:request_sync('codeAction/resolve', action, timeout_ms, bufnr)
    action = response and response.result or action
  end
  if action.command or not action.edit then return nil end
  return action
end

---收集文档或指定行的所有可编辑修复，并生成安全 WorkspaceEdit 事务
---@param opts { bufnr?: integer, line?: integer, character?: integer, timeout_ms?: integer, prefer_fix_all?: boolean }
---@return table? result
---@return table? error
function M.collect_document_fixes(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local timeout_ms = opts.timeout_ms or 3000
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
  local seen = {}

  local function collect(client, params)
    local count = 0
    local response = client:request_sync('textDocument/codeAction', params, timeout_ms, bufnr)
    for _, candidate in ipairs(response and response.result or {}) do
      local action = resolve_action(candidate, client, bufnr, timeout_ms)
      if action then
        local fingerprint = vim.fn.sha256(vim.json.encode({ client = client.id, edit = action.edit }))
        if not seen[fingerprint] then
          seen[fingerprint] = true
          edits[#edits + 1] = {
            edit = action.edit,
            encoding = client.offset_encoding or 'utf-16',
          }
          titles[#titles + 1] = action.title or 'Untitled action'
          client_names[client.name] = true
          count = count + 1
        end
      end
    end
    return count
  end

  for _, client in ipairs(clients) do
    local fix_all_count = prefer_fix_all and collect(client, fix_all_params(bufnr)) or 0
    if fix_all_count == 0 then
      collect(client, request_params(bufnr, target_line, target_character, target_line == nil))
      for _, diagnostic in ipairs(client_diagnostics(bufnr, client, target_line)) do
        collect(client, diagnostic_params(bufnr, diagnostic))
      end
    end
  end

  if #edits == 0 then
    return nil, { code = 'no_quickfixes', message = 'No editable quickfix actions found' }
  end
  local workspace, error = WorkspaceEdit.prepare(edits)
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
---@param opts? { bufnr?: integer, line?: integer, character?: integer, timeout_ms?: integer, prefer_fix_all?: boolean, save?: boolean }
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
  }
end

return M
