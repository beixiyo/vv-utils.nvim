-- Git 子进程生命周期：区分 raw completion、Lua delivery 与物理取消

local M = {}

---启动 Git 子进程，并返回只终止仍在运行 producer 的幂等 cancel
---@param command string[]
---@param opts table
---@param callback fun(result: vim.SystemCompleted)
---@return fun() cancel
---@return any? start_error
function M.start(command, opts, callback)
  local cancelled = false
  local completed = false
  local process

  local function cancel()
    if cancelled then return end
    cancelled = true
    if not completed and process then pcall(process.kill, process, 'sigterm') end
  end

  local ok, result = pcall(vim.system, command, opts, function(value)
    completed = true
    vim.schedule(function()
      if not cancelled then callback(value) end
    end)
  end)

  if ok then
    process = result
    return cancel
  end

  local start_error = result
  vim.schedule(function()
    if cancelled then return end
    completed = true
    callback({ code = -1, signal = 0, stderr = tostring(start_error) })
  end)
  return cancel, start_error
end

return M
