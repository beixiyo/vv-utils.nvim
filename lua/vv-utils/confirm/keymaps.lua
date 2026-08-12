-- 确认框键位：按已归一化的语义动作配置安装 buffer-local 映射

local M = {}

---@param buffer integer
---@param actions VVConfirmActionsConfig
---@param on_confirm fun()
---@param on_cancel fun()
function M.attach(buffer, actions, on_confirm, on_cancel)
  for _, item in ipairs({
    { action = 'confirm', callback = on_confirm },
    { action = 'cancel', callback = on_cancel },
  }) do
    for _, key in ipairs(actions[item.action].keys) do
      vim.keymap.set('n', key, item.callback, {
        buffer = buffer,
        nowait = true,
        silent = true,
      })
    end
  end
end

return M
