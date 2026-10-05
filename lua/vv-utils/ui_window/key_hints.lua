-- vv-utils.ui_window.key_hints — 按键提示列表 → 浮窗边框 title/footer chunks
--
-- 只做纯渲染：把 { key, desc } 列表转换为 nvim_win_set_config 可直接使用的高亮 chunk 数组
-- 键位文本经 vv-utils.keys 统一展示（<CR> → ↵），key 与 desc 使用独立高亮组
-- 宽度不足时按显示宽度整条丢弃尾部条目并追加省略号，绝不把单个 key/desc 截半；
-- 何时写入窗口、何时随尺寸变化重算由调用方决定

local Hl = require('vv-utils.hl')
local Keys = require('vv-utils.keys')

local M = {}

Hl.register('vv-utils.ui_window.key_hints', {
  VVKeyHint = { link = 'Special' },
  VVKeyHintDesc = { link = 'Comment' },
})

local ELLIPSIS = '…'

---@type VVKeyHintsOptions
local defaults = {
  separator = '  ',
  padding = 1,
  key_hl = 'VVKeyHint',
  desc_hl = 'VVKeyHintDesc',
}

local function width_of(text) return vim.fn.strdisplaywidth(text) end

---把单条提示转换为 chunk；key 为空的条目视为无效并跳过
---@param hint VVKeyHint
---@param opts VVKeyHintsOptions
---@return { chunks: [string, string][], width: integer }?
local function entry(hint, opts)
  if type(hint) ~= 'table' or type(hint.key) ~= 'string' or hint.key == '' then return nil end
  local chunks = { { Keys.display(hint.key), opts.key_hl } }
  if type(hint.desc) == 'string' and hint.desc ~= '' then
    chunks[2] = { ' ' .. hint.desc, opts.desc_hl }
  end
  local width = 0
  for _, chunk in ipairs(chunks) do width = width + width_of(chunk[1]) end
  return { chunks = chunks, width = width }
end

---按键提示 → 边框 chunks；可直接作为 nvim_win_set_config 的 footer/title
---
---截断流程：两侧 padding 先计入预算，逐条累加（条目间计 separator）直到下一条放不下；
---发生截断时回退尾部条目直到能放下 separator + 省略号。连一条都放不下时返回 nil
---@param hints VVKeyHint[]
---@param opts? VVKeyHintsOptions
---@return [string, string][]? chunks 空列表或宽度不足时为 nil（nvim 不接受空 chunk 数组）
function M.chunks(hints, opts)
  vim.validate('hints', hints, 'table')
  opts = vim.tbl_extend('force', defaults, opts or {})
  local padding = string.rep(' ', math.max(0, math.floor(opts.padding)))
  local budget = opts.max_width and (math.floor(opts.max_width) - 2 * #padding) or math.huge
  local separator_width = width_of(opts.separator)

  local entries, used, truncated = {}, 0, false
  for _, hint in ipairs(hints) do
    local item = entry(hint, opts)
    if item then
      local next_used = used + (#entries > 0 and separator_width or 0) + item.width
      if next_used > budget then
        truncated = true
        break
      end
      entries[#entries + 1] = item
      used = next_used
    end
  end

  local ellipsis_width = separator_width + width_of(ELLIPSIS)
  if truncated then
    while #entries > 0 and used + ellipsis_width > budget do
      local last = table.remove(entries)
      used = used - last.width - (#entries > 0 and separator_width or 0)
    end
  end
  if #entries == 0 then return nil end

  local result = { { padding, opts.desc_hl } }
  for index, item in ipairs(entries) do
    if index > 1 then result[#result + 1] = { opts.separator, opts.desc_hl } end
    vim.list_extend(result, item.chunks)
  end
  if truncated then result[#result + 1] = { opts.separator .. ELLIPSIS, opts.desc_hl } end
  result[#result + 1] = { padding, opts.desc_hl }
  -- padding = 0 时首尾是空串 chunk，去掉以免 nvim 记录无意义片段
  return vim.tbl_filter(function(chunk) return chunk[1] ~= '' end, result)
end

return M

---@class VVKeyHint
---@field key string 键位记号，展示前经 vv-utils.keys.display 转换（'<CR>' → '↵'）
---@field desc? string 动作描述；缺省只显示键

---@class VVKeyHintsOptions
---@field max_width? integer 可用显示宽度（通常为窗口宽度）；缺省不截断
---@field separator? string 条目间分隔 @default '  '
---@field padding? integer 首尾留白列数 @default 1
---@field key_hl? string 键位高亮组 @default 'VVKeyHint'
---@field desc_hl? string 描述、分隔与留白高亮组 @default 'VVKeyHintDesc'
