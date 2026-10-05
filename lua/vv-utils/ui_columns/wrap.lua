-- vv-utils.ui_columns 折行原语：按显示宽度计算单行屏幕高度、把文本折成定宽片段
--
-- 宽度一律是显示宽度（strdisplaywidth）。字符按 `\zs` 切分，组合字符随基字符一起计宽
-- 输入假定为可打印文本：Tab 的宽度依赖所在列，这里不做列相关修正

local M = {}

local dw = vim.fn.strdisplaywidth

---纯 ASCII 可打印文本每字节宽 1，可直接按字节数计算
---@param text string
---@return boolean
local function is_plain_ascii(text)
  return not text:find('[^\32-\126]')
end

---@param text string
---@return string[] chars
---@return integer[] widths
local function split_chars(text)
  local chars = vim.fn.split(text, '\\zs')
  local widths = {}
  for index, char in ipairs(chars) do
    widths[index] = dw(char)
  end
  return chars, widths
end

---@param char string
---@return boolean
local function is_space(char)
  return char == ' ' or char == '\t'
end

---单行文本在 wrap=true、nolinebreak、宽 width 的窗口中占的屏幕行数
---
---按字符累加显示宽度；宽字符放不下本行剩余宽度时整字换到下一行（与 Neovim 行尾 `>` 占位一致）
---@param text string
---@param width integer
---@return integer
function M.text_height(text, width)
  if is_plain_ascii(text) then
    return math.max(1, math.ceil(#text / width))
  end

  local rows, col = 1, 0
  local _, widths = split_chars(text)

  for _, char_width in ipairs(widths) do
    if col > 0 and col + char_width > width then
      rows, col = rows + 1, 0
    end

    if char_width > width then
      -- 窗口比单个宽字符还窄时，Neovim 先画占位符，再用额外屏幕行显示该字符
      rows = rows + math.ceil(char_width / width)
      col = (char_width - 1) % width + 1
    else
      col = col + char_width
    end
  end
  return rows
end

---折一个逻辑行（不含 '\n'）
---
---贪心填充：放不下下一个字符时，优先回退到本段最后一个空白处断开并丢弃这段空白；
---找不到可用断点（或断开后本段为空）时按字符断。单个字符宽于 width 时独占一段
---@param line string
---@param width integer
---@param break_on_space boolean
---@return string[]
local function wrap_line(line, width, break_on_space)
  if dw(line) <= width then return { line } end

  local chars, widths = split_chars(line)
  local count = #chars
  local pieces = {}
  local start = 1

  while start <= count do
    local col, stop = 0, start
    while stop <= count and col + widths[stop] <= width do
      col = col + widths[stop]
      stop = stop + 1
    end

    if stop > count then
      pieces[#pieces + 1] = table.concat(chars, '', start, count)
      break
    end

    local piece_end, next_start
    if break_on_space then
      for index = stop, start + 1, -1 do
        if is_space(chars[index]) then
          local last = index - 1
          while last >= start and is_space(chars[last]) do last = last - 1 end
          if last >= start then
            local after = index
            while after <= count and is_space(chars[after]) do after = after + 1 end
            piece_end, next_start = last, after
          end
          break
        end
      end
    end

    if not piece_end then
      -- stop == start 说明单个字符就宽于 width：让它独占一段
      piece_end = math.max(stop - 1, start)
      next_start = piece_end + 1
    end

    pieces[#pieces + 1] = table.concat(chars, '', start, piece_end)
    start = next_start
  end

  return pieces
end

---把文本折成显示宽度不超过 width 的片段；先按 '\n' 拆逻辑行再逐行折
---@param text string
---@param width integer
---@param break_on_space boolean
---@return string[]
function M.wrap(text, width, break_on_space)
  local pieces = {}
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    vim.list_extend(pieces, wrap_line(line, width, break_on_space))
  end
  return pieces
end

return M
