---异步子进程生命周期
---
---统一处理启动失败、主循环投递、物理取消与取消后的回调压制
local M = {}
local Callback = require('vv-utils.callback')

---异步启动子进程
---@param command string[]
---@param opts? vv-utils.process.Options vim.system 选项与生命周期回调 @default {}
---@param callback fun(result: vim.SystemCompleted)
---@return fun() cancel 只终止仍在运行的 producer，并压制尚未投递的 callback，幂等
---@return any? start_error 同步启动错误；错误仍会异步投递为 code=-1 的结果
function M.start(command, opts, callback)
  assert(type(command) == 'table' and #command > 0, 'command must be a non-empty list')
  assert(opts == nil or type(opts) == 'table', 'opts must be a table')
  assert(type(callback) == 'function', 'callback must be a function')

  local system_opts = vim.tbl_extend('force', {}, opts or {})
  local on_raw_exit = system_opts.on_raw_exit
  system_opts.on_raw_exit = nil
  assert(on_raw_exit == nil or type(on_raw_exit) == 'function', 'on_raw_exit must be a function')

  local deliver, disable = Callback.limit(callback)
  local cancelled = false
  local completed = false
  local raw_exit_notified = false
  local process

  local function notify_raw_exit(result)
    if raw_exit_notified then return end
    raw_exit_notified = true
    if on_raw_exit then pcall(on_raw_exit, result) end
  end

  local function cancel()
    if cancelled then return end
    cancelled = true
    disable()
    if not completed and process then pcall(process.kill, process, 'sigterm') end
  end

  local started, process_or_error = pcall(vim.system, command, system_opts, function(result)
    completed = true
    notify_raw_exit(result)
    vim.schedule(function()
      if not cancelled then deliver(result) end
    end)
  end)

  if started then
    process = process_or_error
    return cancel
  end

  local start_error = process_or_error
  vim.schedule(function()
    completed = true
    local result = { code = -1, signal = 0, stdout = '', stderr = tostring(start_error) }
    notify_raw_exit(result)
    if not cancelled then deliver(result) end
  end)

  return cancel, start_error
end

---@class vv-utils.process.Options: table
---@field on_raw_exit? fun(result: vim.SystemCompleted) 进程完成后立即调用，即使交付 callback 已被取消 @default nil

return M
