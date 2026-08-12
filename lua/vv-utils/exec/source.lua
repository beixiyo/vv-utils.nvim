-- vv-utils.exec.source 源码前导 token 工具：调用方提供注释语法，模块不绑定具体语言

local M = {}
local UTF8_BOM = '\u{FEFF}'

---@class VVExecSourceCommentSyntax
---@field line? string[] 单行注释起始符，例如 { '//' }
---@field block? { open: string, close: string }[] 块注释边界，例如 { { open = '/*', close = '*/' } }

---@param source string
---@param index integer
---@param syntax? VVExecSourceCommentSyntax
---@return integer?
function M.skip_trivia(source, index, syntax)
  syntax = syntax or {}
  if index == 1 and source:sub(1, #UTF8_BOM) == UTF8_BOM then index = #UTF8_BOM + 1 end

  while index <= #source do
    local char = source:sub(index, index)

    if char:match('%s') then
      index = index + 1
    else
      local skipped = false

      for _, prefix in ipairs(syntax.line or {}) do
        if source:sub(index, index + #prefix - 1) == prefix then
          local newline = source:find('\n', index + #prefix, true)
          index = newline and newline + 1 or #source + 1
          skipped = true
          break
        end
      end

      if not skipped then
        for _, pair in ipairs(syntax.block or {}) do
          if source:sub(index, index + #pair.open - 1) == pair.open then
            local closing = source:find(pair.close, index + #pair.open, true)

            if not closing then return nil end
            index = closing + #pair.close
            skipped = true
            break
          end
        end
      end

      if not skipped then return index end
    end
  end

  return index
end

---@param source string
---@param index integer
---@param start_pattern? string @default '[A-Za-z_]'
---@param continue_pattern? string @default '[A-Za-z0-9_]'
---@return string?, integer
function M.read_identifier(source, index, start_pattern, continue_pattern)
  start_pattern = start_pattern or '[A-Za-z_]'
  continue_pattern = continue_pattern or '[A-Za-z0-9_]'

  if not source:sub(index, index):match(start_pattern) then return nil, index end

  local start = index
  index = index + 1
  while index <= #source and source:sub(index, index):match(continue_pattern) do index = index + 1 end

  return source:sub(start, index - 1), index
end

return M
