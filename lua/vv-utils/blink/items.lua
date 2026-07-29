-- vv-utils 统一候选到 Blink CompletionItem 的转换

local M = {}
local PREFILTERED_RANK_STEP = 16

---@param context VVCompletionContext
---@param result VVCompletionResult
---@return string
local function current_keyword(context, result)
  if context.bounds then
    return context.line:sub(context.bounds.start_col, context.cursor[2])
  end
  return context.line:sub(result.start_col + 1, context.cursor[2])
end

---@param result VVCompletionResult
---@param context VVCompletionContext
---@param max_items integer
---@return VVUtilsBlinkItem[]
function M.convert(result, context, max_items)
  local kinds = require('blink.cmp.types').CompletionItemKind
  local plain_text = vim.lsp.protocol.InsertTextFormat.PlainText
  local row = context.cursor[1] - 1
  local items = {}
  local keyword = result.pre_filtered and current_keyword(context, result) or nil

  for index, candidate in ipairs(result.items or {}) do
    if index > max_items then break end
    local directory = candidate.kind == 'Folder'
    local rank = candidate.rank or index

    items[#items + 1] = {
      label = candidate.abbr or candidate.word,
      filterText = keyword or candidate.word,
      kind = directory and kinds.Folder or kinds.File,
      sortText = result.pre_filtered
          and string.format('%08d', rank)
        or (directory and '0' or '1') .. candidate.word,
      -- 预过滤结果的相邻排名差必须压过 Blink Rust matcher 的 frecency
      -- （最高 6）与 proximity（最高 2），否则仍可能反转调用方顺序
      score_offset = result.pre_filtered and ((max_items - rank) * PREFILTERED_RANK_STEP) or nil,
      insertTextFormat = plain_text,
      textEdit = {
        newText = candidate.word,
        range = {
          start = { line = row, character = result.start_col },
          ['end'] = { line = row, character = context.cursor[2] },
        },
      },
    }
  end

  return items
end

---@class VVUtilsBlinkItem: lsp.CompletionItem
---@field score_offset? number Blink candidate score adjustment

return M
