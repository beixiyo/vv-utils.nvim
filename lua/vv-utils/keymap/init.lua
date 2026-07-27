-- 按 buffer 条件接管映射，并在条件失效或插件关闭时归还。

require('vv-utils.keymap.types')

local Mapping = require('vv-utils.keymap.mapping')
local M = {}
local handles = {}

local function context(buf)
  return {
    buf = buf,
    filetype = vim.bo[buf].filetype,
    buftype = vim.bo[buf].buftype,
  }
end

local function is_active(handle, ctx)
  local opts = handle.opts
  if opts.filetypes and not vim.tbl_contains(opts.filetypes, ctx.filetype) then return false end
  if opts.enabled and not opts.enabled() then return false end
  return not opts.when or opts.when(ctx)
end

local function mappings(handle, ctx)
  local value = handle.opts.mappings
  return type(value) == 'function' and value(ctx) or value
end

local function release_all(handle, buf)
  for map_key in pairs(handle.claims[buf] or {}) do
    Mapping.release(handle, buf, map_key)
  end
end

local function sync_buffer(handle, buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local ctx = context(buf)
  if not is_active(handle, ctx) then
    release_all(handle, buf)
    return
  end

  local desired = {}
  for _, spec in ipairs(mappings(handle, ctx)) do
    local modes = type(spec.mode) == 'table' and spec.mode or { spec.mode }
    for _, mode in ipairs(modes) do desired[Mapping.key(mode, spec.lhs)] = true end
    Mapping.claim(handle, buf, spec)
  end
  for map_key in pairs(handle.claims[buf] or {}) do
    if not desired[map_key] then Mapping.release(handle, buf, map_key) end
  end
end

local function refresh(handle, buf)
  if handle.detached then return end
  if buf then
    sync_buffer(handle, buf)
    return
  end
  for _, listed in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(listed) then sync_buffer(handle, listed) end
  end
end

local function detach(handle)
  if handle.detached then return end
  for buf in pairs(handle.claims) do release_all(handle, buf) end
  pcall(vim.api.nvim_del_augroup_by_id, handle.group)
  handle.detached = true
  if handles[handle.opts.id] == handle then handles[handle.opts.id] = nil end
end

---@param opts VVKeymapAttachOpts
---@return VVKeymapHandle
function M.attach(opts)
  assert(type(opts.id) == 'string' and opts.id ~= '', 'keymap.attach requires a non-empty id')
  assert(type(opts.mappings) == 'table' or type(opts.mappings) == 'function', 'keymap.attach requires mappings')
  if handles[opts.id] then handles[opts.id]:detach() end

  local handle = {
    opts = opts,
    claims = {},
    group = vim.api.nvim_create_augroup('VVUtilsKeymap' .. opts.id:gsub('[^%w]', '_'), { clear = true }),
    detached = false,
  }
  handle.refresh = refresh
  handle.detach = detach
  handles[opts.id] = handle

  vim.api.nvim_create_autocmd(opts.events or 'FileType', {
    group = handle.group,
    callback = function(ev) refresh(handle, ev.buf) end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = handle.group,
    callback = function(ev) handle.claims[ev.buf] = nil end,
  })
  refresh(handle)
  return handle
end

return M
