-- LSP 诊断聚合：遍历所有 loaded buffer，产出 { [abs_path] = { [severity] = count } }
-- 纯数据采集，不订阅 autocmd（让调用方决定刷新时机）
--
-- 典型用法：
--   local D = require('vv-utils.diagnostics')
--   local by_path = D.collect_by_path()
--   local sym = D.symbol_for(by_path['/abs/path.ts']) -- { glyph, hl } 或 nil

local M = {}

local SEV = vim.diagnostic.severity

-- hl 名遵循 'VVDiag*'（默认与 DiagnosticError/Warn/Info/Hint link）
-- 想换 hl / glyph 的调用方可直接自己写 symbol_for 替代本函数
local DEFAULT_HL = {
  [SEV.ERROR] = 'VVDiagError',
  [SEV.WARN]  = 'VVDiagWarn',
  [SEV.INFO]  = 'VVDiagInfo',
  [SEV.HINT]  = 'VVDiagHint',
}

local DEFAULT_GLYPH = {
  [SEV.ERROR] = 'E',
  [SEV.WARN]  = 'W',
  [SEV.INFO]  = 'I',
  [SEV.HINT]  = 'H',
}

-- 按最高 severity 选一个符号（数值越小越严重）
---@param counts table<integer,integer>?  vim.diagnostic.count 的返回
---@return {glyph:string, hl:string}?
function M.symbol_for(counts)
  if not counts then return nil end
  for _, sev in ipairs({ SEV.ERROR, SEV.WARN, SEV.INFO, SEV.HINT }) do
    if counts[sev] and counts[sev] > 0 then
      return { glyph = DEFAULT_GLYPH[sev], hl = DEFAULT_HL[sev] }
    end
  end
  return nil
end

-- 聚合所有已加载 buffer 的诊断计数
---@return table<string, table<integer,integer>>  { [normalized_abs_path] = {[severity]=count} }
function M.collect_by_path()
  local out = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local path = vim.api.nvim_buf_get_name(buf)
      if path ~= '' then
        local counts = vim.diagnostic.count(buf)
        if next(counts) then
          out[vim.fs.normalize(path)] = counts
        end
      end
    end
  end
  return out
end

return M
