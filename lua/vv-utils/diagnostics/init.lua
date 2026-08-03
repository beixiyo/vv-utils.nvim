-- LSP 诊断聚合：遍历所有 loaded buffer，产出 { [abs_path] = { [severity] = count } }
-- 纯数据采集，不订阅 autocmd（让调用方决定刷新时机）
--
-- 典型用法：
--   local D = require('vv-utils.diagnostics')
--   local by_path = D.collect_by_path()
--   local sym = D.symbol_for(by_path['/abs/path.ts']) -- { glyph, hl } 或 nil
--   local lines = D.format_range(0, 42)               -- 第 42 行的诊断文本（复制/发送用）

local M = {}

local SEV = vim.diagnostic.severity

-- 文本标签（按 severity 数值索引，1=Error … 4=Hint），用于复制/发送场景
local SEVERITY_LABELS = { 'Error', 'Warn', 'Info', 'Hint' }

local ICON_NAMES = {
  [SEV.ERROR] = 'diagnostics_error',
  [SEV.WARN]  = 'diagnostics_warn',
  [SEV.INFO]  = 'diagnostics_info',
  [SEV.HINT]  = 'diagnostics_hint',
}

local FALLBACK_HL = {
  [SEV.ERROR] = 'VVDiagError',
  [SEV.WARN]  = 'VVDiagWarn',
  [SEV.INFO]  = 'VVDiagInfo',
  [SEV.HINT]  = 'VVDiagHint',
}

local FALLBACK_GLYPH = {
  [SEV.ERROR] = 'E',
  [SEV.WARN]  = 'W',
  [SEV.INFO]  = 'I',
  [SEV.HINT]  = 'H',
}

local function icon_for(sev)
  local ok, icons = pcall(require, 'vv-icons')
  if ok and icons and type(icons.get) == 'function' then
    local glyph, hl = icons.get('diagnostics', ICON_NAMES[sev])
    if glyph then return glyph, hl or FALLBACK_HL[sev] end
  end

  return FALLBACK_GLYPH[sev], FALLBACK_HL[sev]
end

-- 按最高 severity 选一个符号（数值越小越严重）
---@param counts table<integer,integer>?  vim.diagnostic.count 的返回
---@return {glyph:string, hl:string}?
function M.symbol_for(counts)
  if not counts then return nil end
  for _, sev in ipairs({ SEV.ERROR, SEV.WARN, SEV.INFO, SEV.HINT }) do
    if counts[sev] and counts[sev] > 0 then
      local glyph, hl = icon_for(sev)
      return { glyph = glyph, hl = hl }
    end
  end
  return nil
end

-- 收集 buffer 指定行范围内的诊断，格式化为 "Label: message" 文本行
-- 复制路径 / 发送到 tmux 面板等场景共用，避免各处重复 severity 映射 + 拼接逻辑
---@param buf integer    buffer 号（0 = 当前）
---@param l1 integer      起始行（1-based）
---@param l2? integer     结束行（1-based），默认 = l1
---@return string[]       每条诊断一行 "Label: message"；无诊断返回空表
function M.format_range(buf, l1, l2)
  l2 = l2 or l1
  if l1 > l2 then l1, l2 = l2, l1 end

  local out = {}
  for lnum = l1, l2 do
    for _, d in ipairs(vim.diagnostic.get(buf, { lnum = lnum - 1 })) do
      local label = SEVERITY_LABELS[d.severity] or 'Unknown'
      table.insert(out, label .. ': ' .. d.message)
    end
  end
  return out
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
