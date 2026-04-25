-- 系统集成工具：跨平台分派外部程序

local M = {}

-- 用系统默认程序打开路径；使用 vim.ui.open（Neovim 0.10+ 内置）
---@param path string
function M.open_default(path)
  if not path or path == '' then return end
  vim.ui.open(path)
end

return M
