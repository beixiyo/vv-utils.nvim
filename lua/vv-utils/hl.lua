-- vv-utils.hl — 批量注册 highlight（自动 default=true + ColorScheme 自动重挂）
--
-- 用法：
--   require('vv-utils.hl').register('my-plugin.hl', {
--     MyPluginTitle = { link = 'Title' },
--     MyPluginKey   = { fg = '#81b88b', bold = true },
--   })
--
-- 语义：
--   * default=true 会被自动补上（spec 显式传 default=false 则保留）
--   * colorscheme 切换后自动重新挂载，augroup 幂等 clear

local M = {}

---@param augroup string                            augroup 名（兼作幂等 clear 的 key）
---@param specs table<string, vim.api.keyset.highlight>  name → highlight spec（link 或 fg/bg/... 都可）
---@param opts? { default?: boolean }               default=false 禁用自动补 default=true，默认启用
function M.register(augroup, specs, opts)
  opts = opts or {}
  local auto_default = opts.default ~= false

  local function apply()
    for name, spec in pairs(specs) do
      local s = {}
      for k, v in pairs(spec) do s[k] = v end
      if auto_default and s.default == nil then s.default = true end
      vim.api.nvim_set_hl(0, name, s)
    end
  end

  apply()
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = vim.api.nvim_create_augroup(augroup, { clear = true }),
    callback = apply,
  })
end

--- 读取高亮组的前景色，返回 "#RRGGBB"。
--- 找不到组或无 fg 时返回 fallback（默认 "#ffffff"，避免 lualine color= 回调返回 nil 炸重绘）
---@param name string
---@param fallback? string
---@return string
function M.get_fg(name, fallback)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if ok and hl and hl.fg then return string.format('#%06x', hl.fg) end
  return fallback or '#ffffff'
end

return M
