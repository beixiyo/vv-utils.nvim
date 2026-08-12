-- 通用事务运行时辅助：错误、状态副本和完成回调

local M = {}

M.BUSY_ERROR = 'transaction is busy'
M.LOCKED_ERROR = 'transaction is locked after compensation failure'

function M.copy_states(states)
  local copy = {}
  for index, state in ipairs(states) do
    copy[index] = { operation = state.operation, result = state.result }
  end
  return copy
end

function M.format_failures(failures)
  if #failures == 0 then return '' end
  return '\ncompensation failed:\n' .. table.concat(failures, '\n')
end

function M.append_failure(failures, state, error)
  local name = state.operation.name or 'operation #?'
  failures[#failures + 1] = tostring(name) .. ' (' .. tostring(error) .. ')'
end

function M.safe_callback(callback, ...)
  if callback then pcall(callback, ...) end
end

function M.reject(callback, error)
  M.safe_callback(callback, false, error)
  return false, error
end

return M
