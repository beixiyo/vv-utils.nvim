-- 执行确认适配：把运行计划转为 vv-utils.confirm 的通用内容与动作

local Confirm = require('vv-utils.confirm')
local M = {}

local function argument(value)
  if value:match('^[%w_%%+%-%=,:./@]+$') then
    return value
  end

  local ok, escaped = pcall(vim.fn.shellescape, value)
  return ok and escaped or vim.inspect(value)
end

---@class VVExecConfirmOptions
---@field path string
---@field cwd? string
---@field cmd string[]
---@field target? 'file'|'project' @default 'file'
---@field title? string
---@field notify_prefix? string @default 'vv-utils.exec'
---@field on_confirm fun()
---@field on_cancel? fun() 用户取消确认时调用

---@param opts VVExecConfirmOptions
function M.open(opts)
  local target = opts.target == 'project' and 'project' or 'file'
  local title = opts.title or (target == 'project' and 'Run project entry?' or 'Run file?')
  local label = target == 'project' and 'Project entry' or 'File'
  local value = target == 'project' and (opts.cwd or '(unavailable)') or opts.path
  local command = {}

  for index, item in ipairs(opts.cmd or {}) do
    command[index] = argument(tostring(item))
  end

  local command_line = '$ ' .. (#command > 0 and table.concat(command, ' ') or '(empty argv)')

  return Confirm.open({
    title = title,
    details = {
      { label = label, value = value },
      { label = 'Working directory', value = opts.cwd or '(unavailable)' },
      { label = 'Command', value = command_line, hl = 'String', separator_before = true },
    },
    confirm_label = 'Run',
    confirm_hl = 'DiagnosticOk',
    cancel_label = 'Cancel',
    filetype = 'vv-exec-confirm',
    on_cancel = opts.on_cancel,
    on_confirm = function()
      local ok, err = pcall(opts.on_confirm)
      if not ok then
        vim.notify(
          (opts.notify_prefix or 'vv-utils.exec') .. ': runner failed: ' .. tostring(err),
          vim.log.levels.WARN
        )
      end
    end,
  })
end

return M
