-- 将一段独立源码转换为 tree panel 可渲染的 Tree-sitter 高亮 chunks
--
-- 解析失败或语言无 highlights query 时返回单个 fallback chunk，不修改任何 buffer 或全局状态

local M = {}


---@param text string
---@param lang string?
---@param fallback_hl? string
---@return VVTreePanelChunk[]
function M.chunks(text, lang, fallback_hl)
  fallback_hl = fallback_hl or 'Normal'
  if text == '' or not lang or lang == '' then return { { text, fallback_hl } } end

  local ok, chunks = pcall(function()
    local parser = vim.treesitter.get_string_parser(text, lang)
    local intervals = {} ---@type VVTreePanelSyntaxInterval[]
    local sequence = 0

    parser:parse(true)
    parser:for_each_tree(function(tree, language_tree)
      if not tree then return end

      local tree_lang = language_tree:lang()
      local query = vim.treesitter.query.get(tree_lang, 'highlights')
      if not query then return end

      for id, node, metadata in query:iter_captures(tree:root(), text, 0, 1) do
        metadata = metadata or {}
        local start_row, start_col, end_row, end_col = node:range()
        if start_row == 0 and end_row >= 0 then
          local capture = query.captures[id]
          local finish = end_row == 0 and end_col or #text
          start_col = math.max(0, math.min(start_col, #text))
          finish = math.max(start_col, math.min(finish, #text))

          if capture and finish > start_col then
            sequence = sequence + 1
            intervals[#intervals + 1] = {
              start_col = start_col,
              end_col = finish,
              hl = ('@%s.%s'):format(capture, tree_lang),
              priority = tonumber(metadata.priority or (metadata[id] or {}).priority) or 100,
              sequence = sequence,
            }
          end
        end
      end
    end)

    if #intervals == 0 then return { { text, fallback_hl } } end

    local boundaries = { 0, #text }
    for _, interval in ipairs(intervals) do
      boundaries[#boundaries + 1] = interval.start_col
      boundaries[#boundaries + 1] = interval.end_col
    end
    table.sort(boundaries)

    local result = {}
    local previous_boundary
    for _, boundary in ipairs(boundaries) do
      if previous_boundary and boundary > previous_boundary then
        local selected
        for _, interval in ipairs(intervals) do
          if interval.start_col <= previous_boundary and interval.end_col >= boundary
              and (not selected
                or interval.priority > selected.priority
                or (interval.priority == selected.priority
                  and interval.sequence > selected.sequence))
          then
            selected = interval
          end
        end

        local hl = selected and selected.hl or fallback_hl
        local part = text:sub(previous_boundary + 1, boundary)
        local last = result[#result]
        if last and last[2] == hl then
          last[1] = last[1] .. part
        else
          result[#result + 1] = { part, hl }
        end
      end
      previous_boundary = boundary
    end

    return result
  end)

  return ok and chunks or { { text, fallback_hl } }
end

return M
