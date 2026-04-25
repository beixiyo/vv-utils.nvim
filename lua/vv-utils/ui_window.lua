-- UI buffer 的 window chrome 管理
--
-- 场景：dashboard / vv-explorer 这类"面板型" buffer 不想显示行号、
-- signcolumn、statuscolumn 等编辑器装饰。
--
-- 坑：number / cursorline / wrap 等是 window-local 选项，关掉后
-- 不会随 buffer 销毁恢复——如果把 UI buf 挂在用户主窗口（而非新 split），
-- buf wipe 后行号设置残留，用户在该窗口打开源码文件仍然没行号。
--
-- 本模块两条路子：
--   1) hide_chrome(win, overrides?) → 返回 restore()，调用方自己决定时机
--   2) hide_chrome_until_buf_wiped(win, buf, overrides?) → 自动在
--      BufWipeout/BufDelete 时 restore（适合 dashboard 这种复用当前窗口的场景）
-- 独立 split 的插件（如 vv-explorer）丢弃 restore 即可——窗口销毁后选项跟着消失。

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
    saved[opt] = vim.wo[win][opt]
  end
  for opt, val in pairs(target) do
    vim.wo[win][opt] = val
  end
  return function()
    if not vim.api.nvim_win_is_valid(win) then return end
    for opt, val in pairs(saved) do
      vim.wo[win][opt] = val
    end
  end
end

-- 把 win 的"装饰"选项强制拉回全局默认（vim.go.X）。
-- 用途：从 UI 窗口（如 vv-explorer）`:vsplit` 出来的新窗口，会继承 UI 窗口的
-- 隐藏状态（number=false 等）；调用此函数把它"重置"回用户在 options.lua 里
-- 配置的全局值，新窗口看起来就是一个正常文件窗口。
---@param win integer
function M.show_chrome(win)
  if not vim.api.nvim_win_is_valid(win) then return end
  for opt, _ in pairs(M.DEFAULT_OPTS) do
    vim.wo[win][opt] = vim.go[opt]
  end
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
