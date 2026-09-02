-- Git 冲突原语：识别 porcelain unmerged 状态并解析工作区冲突标记

local M = {}

---@param xy string?
---@return boolean
function M.is_conflict(xy)
  if type(xy) ~= 'string' then return false end

  local first = xy:sub(1, 1)
  local second = xy:sub(2, 2)
  return xy == 'AA' or xy == 'DD' or first == 'U' or second == 'U'
end

---@class vv-utils.git.ConflictHunk
---@field start_line integer `<<<<<<<` 所在行，1-based
---@field base_line? integer `|||||||` 所在行，1-based
---@field separator_line integer `=======` 所在行，1-based
---@field end_line integer `>>>>>>>` 所在行，1-based

-- Git 只写出恰好七个标记字符，后接行尾或空格加标签；更长的分隔横幅、
-- 或七个字符后紧跟其它文本的行都不是冲突标记，避免误判普通文本并触发破坏性替换
---@param line string
---@param marker string
---@return boolean
local function is_marker(line, marker)
  return line == marker or line:sub(1, #marker + 1) == marker .. ' '
end

---解析普通、diff3 与 zdiff3 格式的完整冲突块
---@param lines string[]
---@return vv-utils.git.ConflictHunk[]
function M.parse_conflict_hunks(lines)
  local hunks = {}
  local index = 1

  while index <= #(lines or {}) do
    if is_marker(lines[index], '<<<<<<<') then
      local hunk = { start_line = index }
      index = index + 1

      while index <= #lines and not is_marker(lines[index], '=======') do
        if not hunk.base_line and is_marker(lines[index], '|||||||') then
          hunk.base_line = index
        end
        index = index + 1
      end
      if index > #lines then break end

      hunk.separator_line = index
      index = index + 1
      while index <= #lines and not is_marker(lines[index], '>>>>>>>') do
        index = index + 1
      end
      if index > #lines then break end

      hunk.end_line = index
      hunks[#hunks + 1] = hunk
      index = index + 1
    else
      index = index + 1
    end
  end

  return hunks
end

return M
