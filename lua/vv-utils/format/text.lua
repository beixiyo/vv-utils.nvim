-- 中英文排版与行尾文本清理
--
-- 只处理传入字符串，不读写 buffer、项目文件或模块配置

local M = {}

-- 中文范围：CJK Unified Ideographs 主区段（U+4E00-U+9FA5）
-- 左侧：中文；右侧：(允许的前缀符号*)英数。前缀符号：@#$¥€£+_-*~`[
local LEFT_PATTERN = [=[\([一-龥]\)\([@#$¥€£+_\-*~`[]*[A-Za-z0-9]\)]=]
-- 左侧：英数(允许的后缀符号*)；右侧：中文。后缀符号：+-%‰°_*~`)]
local RIGHT_PATTERN = [=[\([A-Za-z0-9][+\-%‰°_*~`)\]]*\)\([一-龥]\)]=]

-- 行尾「闭合符」：markdown 强调 / 行内代码 / 删除线 + 各类闭合括号 / 引号
local TRAILING_CLOSERS = {
  '*', '_', '`', '~',
  ')', ']', '}', '）', '】', '》', '」', '』', '〉', '〕', '］', '｝',
  '”', '“', '’', '‘', '"', "'",
}

local FENCED_COMMENT_PATTERNS = {
  '^%s*#',
  '^%s*//',
  '^%s*%-%-',
}

---@param line string
---@param puncts string[]
---@param peel_closers boolean
---@return string
local function clean_one_line(line, puncts, peel_closers)
  while true do
    local before = line
    line = line:gsub('[ \t]+$', '')
    for _, punct in ipairs(puncts) do
      if vim.endswith(line, punct) then
        line = line:sub(1, #line - #punct)
        break
      end
    end
    if line == before then break end
  end
  if not peel_closers then return line end

  local closers = {}
  while true do
    local matched = false
    for _, closer in ipairs(TRAILING_CLOSERS) do
      if vim.endswith(line, closer) then
        closers[#closers + 1] = closer
        line = line:sub(1, #line - #closer)
        matched = true
        break
      end
    end
    if not matched then break end
  end

  while true do
    local matched = false
    for _, punct in ipairs(puncts) do
      if vim.endswith(line, punct) then
        line = line:sub(1, #line - #punct)
        matched = true
        break
      end
    end
    if not matched then break end
  end

  for index = #closers, 1, -1 do line = line .. closers[index] end
  return line
end

---@param line string
---@param puncts string[]
---@return string
local function clean_fenced_code_line(line, puncts)
  local trimmed = line:gsub('[ \t]+$', '')
  for _, pattern in ipairs(FENCED_COMMENT_PATTERNS) do
    if trimmed:match(pattern) then return clean_one_line(line, puncts, false) end
  end
  return trimmed
end

---中英文之间智能加空格
---@param text string
---@return string
function M.add_spaces_around_english(text)
  text = vim.fn.substitute(text, LEFT_PATTERN, [[\1 \2]], 'g')
  text = vim.fn.substitute(text, RIGHT_PATTERN, [[\1 \2]], 'g')
  return text
end

---清理散文行尾；代码围栏内只清注释行句号
---@param text string
---@param puncts string[]
---@return string
function M.clean_prose(text, puncts)
  local lines = vim.split(text, '\n', { plain = true })
  local in_code = false
  for index, line in ipairs(lines) do
    if line:match('^%s*```') or line:match('^%s*~~~') then
      in_code = not in_code
    elseif in_code then
      lines[index] = clean_fenced_code_line(line, puncts)
    else
      lines[index] = clean_one_line(line, puncts, true)
    end
  end
  return table.concat(lines, '\n')
end

---清理代码或配置文件行尾
---@param text string
---@param puncts string[]
---@return string
function M.clean_code(text, puncts)
  local lines = vim.split(text, '\n', { plain = true })
  for index, line in ipairs(lines) do
    lines[index] = clean_one_line(line, puncts, false)
  end
  return table.concat(lines, '\n')
end

return M
