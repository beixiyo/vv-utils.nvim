-- 自测首次运行时准备固定版本 mini.test；行为 fixture 阶段不下载依赖
local directory = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')

local ok, err = xpcall(function()
  dofile(directory .. '/deps.lua').ensure_mini_test()
end, debug.traceback)

if not ok then io.stderr:write(tostring(err) .. '\n') end
vim.cmd(ok and '0cquit' or '1cquit')
