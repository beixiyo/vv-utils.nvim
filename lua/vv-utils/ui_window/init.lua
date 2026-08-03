-- UI buffer 的 window chrome 管理
--
-- 场景：dashboard / vv-explorer 这类"面板型" buffer 不想显示行号、
-- signcolumn、statuscolumn 等编辑器装饰
--
-- 坑：number / cursorline / wrap 等是 window-local 选项，关掉后
-- 不会随 buffer 销毁恢复——如果把 UI buf 挂在用户主窗口（而非新 split），
-- buf wipe 后行号设置残留，用户在该窗口打开源码文件仍然没行号
--
-- 本模块两条路子：
--   1) hide_chrome(win, overrides?) → 返回 restore()，调用方自己决定时机
--   2) hide_chrome_until_buf_wiped(win, buf, overrides?) → 自动在
--      BufWipeout/BufDelete 时 restore（适合 dashboard 这种复用当前窗口的场景）
-- 独立 split 的插件（如 vv-explorer）丢弃 restore 即可——窗口销毁后选项跟着消失

local M = {}

---@type table<string, any>
M.DEFAULT_OPTS = {
  number = false,
  relativenumber = false,
  signcolumn = 'no',
  foldcolumn = '0',
  statuscolumn = '',
  cursorline = false,
  wrap = false,
  list = false,
  spell = false,
}

---@param win integer
---@param overrides? table<string, any>
---@return fun() restore  把 win 恢复到调用前的选项值（win 无效时 no-op）
function M.hide_chrome(win, overrides)
  local target = vim.tbl_extend('force', M.DEFAULT_OPTS, overrides or {})
  local saved = {}
  for opt, _ in pairs(target) do
    saved[opt] = vim.api.nvim_get_option_value(opt, { win = win })
  end
  -- scope='local'：只改本窗口，不污染全局默认值
  -- vim.wo[win] 等于 :set，会同时改全局默认 → 后续新建窗口全部继承 number=false
  for opt, val in pairs(target) do
    vim.api.nvim_set_option_value(opt, val, { win = win, scope = 'local' })
  end
  return function()
    if not vim.api.nvim_win_is_valid(win) then return end
    for opt, val in pairs(saved) do
      vim.api.nvim_set_option_value(opt, val, { win = win, scope = 'local' })
    end
  end
end

-- 把 win 的"装饰"选项强制拉回全局默认（vim.go.X）
-- 用途：从 UI 窗口（如 vv-explorer）`:vsplit` 出来的新窗口，会继承 UI 窗口的
-- 隐藏状态（number=false 等）；调用此函数把它"重置"回用户在 options.lua 里
-- 配置的全局值，新窗口看起来就是一个正常文件窗口
---@param win integer
function M.show_chrome(win)
  if not vim.api.nvim_win_is_valid(win) then return end
  for opt, _ in pairs(M.DEFAULT_OPTS) do
    local val = vim.api.nvim_get_option_value(opt, { scope = 'global' })
    vim.api.nvim_set_option_value(opt, val, { win = win, scope = 'local' })
  end
end

---确保一个 buffer 在指定 tab 内只显示于一个窗口
---
---UI panel 的状态通常只持有一个 window handle，但 Neovim 允许同一 buffer
---同时挂到多个窗口。布局迁移出现竞态时，多余窗口会脱离插件状态成为 orphan
---这里以实际 window graph 为准收敛状态；优先保留 preferred，其次保留首个窗口
---@param tab integer
---@param buf integer
---@param preferred? integer
---@return integer? keeper
---@return integer[] closed
function M.ensure_unique_buffer_window(tab, buf, preferred)
  if not vim.api.nvim_tabpage_is_valid(tab) or not vim.api.nvim_buf_is_valid(buf) then
    return nil, {}
  end

  local windows = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      windows[#windows + 1] = win
    end
  end

  local keeper
  if preferred and vim.tbl_contains(windows, preferred) then
    keeper = preferred
  else
    keeper = windows[1]
  end

  local closed = {}
  for _, win in ipairs(windows) do
    if win ~= keeper then
      local ok = pcall(vim.api.nvim_win_close, win, true)
      if ok then closed[#closed + 1] = win end
    end
  end

  return keeper, closed
end

---@param win integer
---@param buf integer  buf 被销毁时自动 restore（BufWipeout / BufDelete）
---@param overrides? table<string, any>
function M.hide_chrome_until_buf_wiped(win, buf, overrides)
  local restore = M.hide_chrome(win, overrides)
  vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufDelete' }, {
    buffer = buf,
    once = true,
    callback = restore,
  })
end

return M
