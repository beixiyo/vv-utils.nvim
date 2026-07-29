-- Highlight 注册生命周期：批量挂载原始组与基于现有组派生的低对比度组

local color = require('vv-utils.color')

local M = {}

---@param name string
---@return vim.api.keyset.get_hl_info
local function resolved(name)
  local ok, value = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  return ok and value or {}
end

---@param augroup string
---@param apply fun()
---@param derived? boolean
local function on_colorscheme(augroup, apply, derived)
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = vim.api.nvim_create_augroup(augroup, { clear = true }),
    callback = function()
      vim.schedule(function()
        if derived then
          -- 来源组由其他模块恢复；派生组固定晚一个调度阶段读取最终颜色
          vim.schedule(apply)
        else
          apply()
        end
      end)
    end,
  })
end

---批量注册 highlight，并在 colorscheme 切换后重新挂载
---@param augroup string augroup 名（兼作幂等 clear 的 key）
---@param specs table<string, vim.api.keyset.highlight> 高亮名到 spec
---@param opts? { default?: boolean } `default=false` 禁用自动补 `default=true`
function M.register(augroup, specs, opts)
  opts = opts or {}
  local auto_default = opts.default ~= false

  local function apply()
    for name, spec in pairs(specs) do
      local value = {}
      for key, field in pairs(spec) do value[key] = field end
      if auto_default and value.default == nil then value.default = true end
      vim.api.nvim_set_hl(0, name, value)
    end
  end

  apply()
  on_colorscheme(augroup, apply)
end

---注册从现有高亮派生的低对比度高亮
---@param augroup string
---@param specs table<string, string> 目标高亮名到来源高亮名
---@param opts? { amount?: number, background?: string }
function M.register_dimmed(augroup, specs, opts)
  opts = opts or {}
  local amount = opts.amount or 0.7
  if type(amount) ~= 'number' or amount < 0 or amount > 1 then
    error('vv-utils.hl: dim amount must be a number between 0 and 1')
  end
  local background_group = opts.background or 'Normal'

  local function apply()
    local background_hl = resolved(background_group)
    local normal = resolved('Normal')
    local background = type(background_hl.bg) == 'number' and background_hl.bg
      or type(normal.bg) == 'number' and normal.bg
      or 0

    for target, source in pairs(specs) do
      local source_hl = resolved(source)
      local spec = {} ---@type vim.api.keyset.highlight
      for key, value in pairs(source_hl) do spec[key] = value end
      spec.link = nil
      spec.default = false
      if type(source_hl.fg) == 'number' then
        spec.fg = color.to_integer(color.mix(source_hl.fg, background, amount))
      end
      vim.api.nvim_set_hl(0, target, spec)
    end
  end

  apply()
  on_colorscheme(augroup, apply, true)
end

---读取高亮组的前景色
---@param name string
---@param fallback? string
---@return string color `#RRGGBB`
function M.get_fg(name, fallback)
  local value = resolved(name)
  if type(value.fg) == 'number' then return string.format('#%06x', value.fg) end
  return fallback or '#ffffff'
end

return M
