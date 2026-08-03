-- buffer-local 映射的快照、所有权判定与恢复

local M = {}

function M.key(mode, lhs)
  return mode .. '\0' .. lhs
end

function M.get(buf, mode, lhs)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
    if map.lhs == lhs then return map end
  end
end

function M.is_owned(current, installed)
  return current and installed
    and current.callback == installed.callback
    and current.rhs == installed.rhs
    and current.desc == installed.desc
end

function M.restore(buf, map)
  if not map then return end
  vim.keymap.set(map.mode or 'n', map.lhs, map.callback or map.rhs, {
    buffer = buf,
    desc = map.desc,
    silent = map.silent == 1,
    nowait = map.nowait == 1,
    expr = map.expr == 1,
    remap = map.noremap == 0,
    script = map.script == 1,
    replace_keycodes = map.replace_keycodes == 1,
  })
end

---@param handle VVKeymapHandleState
function M.release(handle, buf, map_key)
  local claims = handle.claims[buf]
  local claim = claims and claims[map_key]
  if not claim then return end

  if vim.api.nvim_buf_is_valid(buf) and M.is_owned(M.get(buf, claim.mode, claim.lhs), claim.installed) then
    pcall(vim.keymap.del, claim.mode, claim.lhs, { buffer = buf })
    M.restore(buf, claim.previous)
  end

  claims[map_key] = nil
  if not next(claims) then handle.claims[buf] = nil end
end

---@param handle VVKeymapHandleState
---@param spec VVKeymapSpec
function M.claim(handle, buf, spec)
  local modes = type(spec.mode) == 'table' and spec.mode or { spec.mode }
  for _, mode in ipairs(modes) do
    local map_key = M.key(mode, spec.lhs)
    local claims = handle.claims[buf] or {}
    handle.claims[buf] = claims
    if not claims[map_key] then
      claims[map_key] = { mode = mode, lhs = spec.lhs, previous = M.get(buf, mode, spec.lhs) }
      vim.keymap.set(mode, spec.lhs, spec.rhs, vim.tbl_extend('force', spec.opts or {}, { buffer = buf }))
      claims[map_key].installed = M.get(buf, mode, spec.lhs)
    end
  end
end

return M
