-- 仅使用显式冻结的 runtime 根目录。绝不递归 package 目录或加载 init
local M = {}

function M.apply()
  local site = vim.env.VV_TEST_SITE
  if site and vim.fn.isdirectory(site) == 1 then
    vim.opt.runtimepath:append(site)
  end
  for root in (vim.env.VV_TEST_RUNTIME_PATHS or ''):gmatch('[^\n]+') do
    assert(vim.fn.isdirectory(root) == 1, 'test runtime directory missing: ' .. root)
    vim.opt.runtimepath:append(root)
  end
end

return M
