-- 通用颜色工具：统一解析、格式化、混合与合成 RGB / RGBA

local M = {}

---@class VVColorRGBA
---@field r integer 红色通道，0-255
---@field g integer 绿色通道，0-255
---@field b integer 蓝色通道，0-255
---@field a integer Alpha 通道，0-255

---@alias VVColorInput integer|string|VVColorRGBA
---@alias VVColorHexAlpha 'auto'|'always'|'never'

---@param name string
---@param value any
---@return integer
local function channel(name, value)
  if type(value) ~= 'number' or value % 1 ~= 0 or value < 0 or value > 255 then
    error(('vv-utils.color: %s must be an integer between 0 and 255'):format(name))
  end
  return value
end

---@param value integer
---@return VVColorRGBA
local function parse_integer(value)
  if value % 1 ~= 0 or value < 0 or value > 0xffffff then
    error('vv-utils.color: integer color must be between 0x000000 and 0xffffff')
  end

  return {
    r = math.floor(value / 0x10000) % 0x100,
    g = math.floor(value / 0x100) % 0x100,
    b = value % 0x100,
    a = 255,
  }
end

---@param value string
---@return VVColorRGBA
local function parse_hex(value)
  local hex = value:match('^#([%da-fA-F]+)$')
  if not hex or not vim.tbl_contains({ 3, 4, 6, 8 }, #hex) then
    error('vv-utils.color: hex color must use #RGB, #RGBA, #RRGGBB, or #RRGGBBAA')
  end

  if #hex == 3 or #hex == 4 then
    hex = hex:gsub('.', function(part) return part .. part end)
  end
  if #hex == 6 then hex = hex .. 'ff' end

  return {
    r = assert(tonumber(hex:sub(1, 2), 16)),
    g = assert(tonumber(hex:sub(3, 4), 16)),
    b = assert(tonumber(hex:sub(5, 6), 16)),
    a = assert(tonumber(hex:sub(7, 8), 16)),
  }
end

---将支持的颜色输入归一化为独立 RGBA 对象
---@param value VVColorInput
---@return VVColorRGBA
function M.parse(value)
  if type(value) == 'number' then return parse_integer(value) end
  if type(value) == 'string' then return parse_hex(value) end
  if type(value) ~= 'table' then
    error('vv-utils.color: color must be an integer, hex string, or RGBA table')
  end

  return {
    r = channel('r', value.r),
    g = channel('g', value.g),
    b = channel('b', value.b),
    a = channel('a', value.a == nil and 255 or value.a),
  }
end

---格式化为小写 Hex；默认仅在非不透明时包含 alpha
---@param value VVColorInput
---@param opts? { alpha?: VVColorHexAlpha }
---@return string
function M.to_hex(value, opts)
  opts = opts or {}
  local alpha = opts.alpha or 'auto'
  if not vim.tbl_contains({ 'auto', 'always', 'never' }, alpha) then
    error("vv-utils.color: alpha must be 'auto', 'always', or 'never'")
  end

  local parsed = M.parse(value)
  local result = ('#%02x%02x%02x'):format(parsed.r, parsed.g, parsed.b)
  if alpha == 'always' or alpha == 'auto' and parsed.a < 255 then
    result = result .. ('%02x'):format(parsed.a)
  end
  return result
end

---转换为 Neovim 使用的 `0xRRGGBB` integer
---@param value VVColorInput
---@param opts? { background?: VVColorInput, discard_alpha?: boolean }
---@return integer
function M.to_integer(value, opts)
  opts = opts or {}
  local parsed = M.parse(value)
  if parsed.a < 255 then
    if opts.background ~= nil then
      parsed = M.composite(parsed, opts.background)
    end
    if parsed.a < 255 and not opts.discard_alpha then
      error('vv-utils.color: translucent color requires background or discard_alpha=true')
    end
  end
  return parsed.r * 0x10000 + parsed.g * 0x100 + parsed.b
end

---@param first VVColorInput
---@param second VVColorInput
---@param amount number
---@return VVColorRGBA
function M.mix(first, second, amount)
  if type(amount) ~= 'number' or amount < 0 or amount > 1 then
    error('vv-utils.color: amount must be a number between 0 and 1')
  end
  local from = M.parse(first)
  local to = M.parse(second)
  local keep = 1 - amount
  local function interpolate(a, b)
    return math.floor(a * keep + b * amount + 0.5)
  end

  return {
    r = interpolate(from.r, to.r),
    g = interpolate(from.g, to.g),
    b = interpolate(from.b, to.b),
    a = interpolate(from.a, to.a),
  }
end

---按 source-over 规则将 foreground 合成到 background
---@param foreground VVColorInput
---@param background VVColorInput
---@return VVColorRGBA
function M.composite(foreground, background)
  local front = M.parse(foreground)
  local back = M.parse(background)
  local front_alpha = front.a / 255
  local back_alpha = back.a / 255
  local output_alpha = front_alpha + back_alpha * (1 - front_alpha)
  if output_alpha == 0 then return { r = 0, g = 0, b = 0, a = 0 } end

  local function compose(front_channel, back_channel)
    local value = front_channel * front_alpha
      + back_channel * back_alpha * (1 - front_alpha)
    return math.floor(value / output_alpha + 0.5)
  end

  return {
    r = compose(front.r, back.r),
    g = compose(front.g, back.g),
    b = compose(front.b, back.b),
    a = math.floor(output_alpha * 255 + 0.5),
  }
end

return M
