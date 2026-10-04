-- 测试进程清理：在停止 owning Neovim 前回收它当前拥有的后代，避免 shell 留下孙进程
local M = {}

--- 按实时父子关系先停止最深层进程；只能传入本测试实际启动的 Neovim PID
---@param pid integer? 启动失败、尚无 PID 时不做清理
function M.stop_descendants(pid)
  if not pid then return end
  assert(pid > 1, '测试子进程 PID 必须有效')
  local result = vim.system({ 'ps', '-eo', 'pid=,ppid=' }, { text = true }):wait()
  assert(result.code == 0, '无法查询 fixture 进程树：' .. tostring(result.stderr))
  local children = {}
  for line in (result.stdout or ''):gmatch('[^\n]+') do
    local id, parent = line:match('^%s*(%d+)%s+(%d+)')
    if id then
      parent = tonumber(parent)
      children[parent] = children[parent] or {}
      table.insert(children[parent], tonumber(id))
    end
  end
  local function stop(parent)
    for _, id in ipairs(children[parent] or {}) do
      stop(id)
      local ok, err = vim.uv.kill(id, 'sigkill')
      assert(ok or tostring(err):find('ESRCH', 1, true), '无法停止 fixture 后代：' .. id .. ' ' .. tostring(err))
    end
  end
  stop(pid)
end

return M
