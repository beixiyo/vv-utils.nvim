-- 浮窗背景遮罩：在目标浮窗下面垫一层铺满编辑器的半透明窗口，压暗其余界面
--
-- 遮罩只是视觉层：不可聚焦、不拦截鼠标，生命周期跟随目标窗口

local Hl = require('vv-utils.hl')

local M = {}

Hl.register('vv-utils.ui_window.backdrop', {
  VVBackdrop = { bg = '#000000' },
})

local DEFAULT_ZINDEX = 50 -- nvim_open_win 对浮窗的默认值

---终端不支持真彩或 Normal 没有背景色（透明终端）时，混合不出压暗效果，只会得到一块纯黑
---@return boolean
local function supported()
  if not vim.o.termguicolors then return false end
  local ok, normal = pcall(vim.api.nvim_get_hl, 0, { name = 'Normal', link = false })
  return ok and normal.bg ~= nil
end

---@param win integer 目标浮窗
---@param opts? VVBackdropOptions
---@return VVBackdropHandle? handle 不支持遮罩或目标不是浮窗时为 nil
function M.open(win, opts)
  opts = opts or {}
  if not vim.api.nvim_win_is_valid(win) or not supported() then return nil end

  local target = vim.api.nvim_win_get_config(win)
  if target.relative == '' then return nil end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  -- 供其它插件按 filetype 排除（滚动条、缩进线等不该画在遮罩上）
  vim.bo[buf].filetype = 'vv-backdrop'

  local backdrop = vim.api.nvim_open_win(buf, false, {
    relative = 'editor',
    row = 0,
    col = 0,
    width = vim.o.columns,
    height = vim.o.lines,
    style = 'minimal',
    border = 'none',
    focusable = false,
    mouse = false,
    noautocmd = true,
    zindex = math.max(1, (target.zindex or DEFAULT_ZINDEX) - 1),
  })
  vim.api.nvim_set_option_value('winhighlight', 'Normal:VVBackdrop', { win = backdrop, scope = 'local' })
  vim.api.nvim_set_option_value('winblend', opts.blend or 60, { win = backdrop, scope = 'local' })

  local group = vim.api.nvim_create_augroup('vv-utils.ui_window.backdrop.' .. backdrop, { clear = true })
  local closed = false

  local function close()
    if closed then return end
    closed = true
    pcall(vim.api.nvim_del_augroup_by_id, group)
    if vim.api.nvim_win_is_valid(backdrop) then pcall(vim.api.nvim_win_close, backdrop, true) end
  end

  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    pattern = tostring(win),
    -- WinClosed 期间不能再关窗口
    callback = function() vim.schedule(close) end,
  })
  vim.api.nvim_create_autocmd('VimResized', {
    group = group,
    callback = function()
      if not vim.api.nvim_win_is_valid(backdrop) then return end
      vim.api.nvim_win_set_config(backdrop, {
        relative = 'editor', row = 0, col = 0, width = vim.o.columns, height = vim.o.lines,
      })
    end,
  })

  return { win = backdrop, close = close }
end

return M

---@class VVBackdropOptions
---@field blend? integer 遮罩的 'winblend'，越小越暗 @default 60

---@class VVBackdropHandle
---@field win integer
---@field close fun() 幂等；目标窗口关闭时自动调用
