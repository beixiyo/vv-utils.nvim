-- vv-utils.keys — 将 Neovim 键位记号转换为紧凑、跨 UI 一致的展示文本

local M = {}

local modifiers = {
  C = '^',
  M = '⌥',
  A = '⌥',
  S = '⇧',
  D = '⌘',
}

local special_keys = {
  CR = '↵',
  -- <NL> 是 Ctrl-J，不能与 <CR> 合并；宏和映射可能同时包含两者
  NL = '^j',
  -- keytrans() 会把字面量左尖括号表示成 <lt>
  lt = '<',
  -- 空格作为 <leader> 时必须在帮助文本中保持可见
  Space = '␠',
}

local modifier_order = { 'C', 'M', 'S', 'D' }

---@param value string
---@return string
local function canonical(value)
  -- keycode() 同时展开 leader，并编码 <C-W>q 这类复合记号
  -- 仅在存在尖括号 token 时调用，避免改写普通字符串和已编码字节
  if value:find('<[^>]+>', 1) then
    value = vim.keycode(value)
  end
  return vim.fn.keytrans(value)
end

---@param value string
---@return string[]
local function tokens(value)
  local result = {}
  local index = 1

  while index <= #value do
    local start = value:find('<', index, true)

    if start == index then
      local finish = value:find('>', index + 1, true)
      if finish then
        result[#result + 1] = value:sub(index, finish)
        index = finish + 1
      else
        result[#result + 1] = value:sub(index, index)
        index = index + 1
      end
    elseif value:sub(index, index) == '^' and index < #value
      and value:sub(index + 1, index + 1):match('[A-Z]') then
      result[#result + 1] = value:sub(index, index + 1)
      index = index + 2
    else
      if start and start > index then
        for char in value:sub(index, start - 1):gmatch('.') do
          result[#result + 1] = char
        end
        index = start
      else
        result[#result + 1] = value:sub(index, index)
        index = index + 1
      end
    end
  end

  return result
end

---@param token string
---@return string
local function display_token(token)
  local name = token:match('^<(.*)>$')
  if name then
    if special_keys[name] then return special_keys[name] end

    local active = {}
    local has_modifier = false
    local has_shift = false
    local key = name

    while true do
      local modifier, rest = key:match('^([CMASD])%-(.+)$')
      if not modifier then break end
      active[modifier == 'A' and 'M' or modifier] = true
      has_modifier = true
      has_shift = has_shift or modifier == 'S'
      key = rest
    end

    if has_modifier and #key == 1 then
      -- keytrans() 会把修饰键后的字母规范为大写；紧凑提示仅在含 Shift 时保留大写
      key = has_shift and key:upper() or key:lower()
    end

    local hints = {}
    for _, modifier in ipairs(modifier_order) do
      if active[modifier] then hints[#hints + 1] = modifiers[modifier] end
    end
    return table.concat(hints) .. key
  end

  local control = token:match('^%^([A-Z])$')
  if control then return '^' .. control:lower() end
  if token:match('^[A-Z]$') then return modifiers.S .. token end
  return token
end

---@param lhs string Neovim 键位记号或已编码的键值，例如 '<C-y>'、'<M-p>'、'<CR>'
---@return string
function M.display(lhs)
  assert(type(lhs) == 'string', 'vv-utils.keys.display expects a string')
  local display = {}
  for _, token in ipairs(tokens(canonical(lhs))) do
    display[#display + 1] = display_token(token)
  end
  return table.concat(display)
end

---@param action string
---@param lhs string
---@return string
function M.hint(action, lhs)
  return action .. ' ' .. M.display(lhs)
end

return M
