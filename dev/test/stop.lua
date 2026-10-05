-- 收到信号时，仅清理本次调用拥有的 Neovim 进程
local runner = vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))
local ok, err = pcall(dofile(runner .. '/process.lua').stop_descendants, tonumber(arg[1]))
if not ok then
  io.stderr:write(tostring(err) .. '\n')
end
vim.cmd(ok and '0cquit' or '1cquit')
