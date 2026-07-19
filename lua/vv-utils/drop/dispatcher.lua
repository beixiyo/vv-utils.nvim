-- 拖拽分发：维护路径 handler 链与拖拽过程订阅

local M = {}

---@type (fun(paths: string[], pos: vv-utils.drop.Position?): boolean?)[]
local handlers = {}

---@type (fun(ev: vv-utils.drop.DragEvent): nil)[]
local drag_handlers = {}

--- 注册拖拽处理器，返回 true 表示已消费，阻止后续 handler
---@param handler fun(paths: string[], pos: vv-utils.drop.Position?): boolean?
function M.register(handler)
  handlers[#handlers + 1] = handler
end

--- 订阅拖拽移动 / 离开事件（仅 kitty DnD 协议下触发），用于实时高亮落点
---@param handler fun(ev: vv-utils.drop.DragEvent): nil
function M.on_drag(handler)
  drag_handlers[#drag_handlers + 1] = handler
end

---@param event vv-utils.drop.DragEvent
function M.fire_drag(event)
  for _, handler in ipairs(drag_handlers) do
    pcall(handler, event)
  end
end

--- 默认 handler：Normal 模式 + 普通 buffer 下打开文件
---@param paths string[]
---@return boolean
local function default_handler(paths)
  local mode = vim.fn.mode()
  if mode ~= 'n' and mode ~= 'nt' then return false end
  if vim.bo.buftype ~= '' then return false end

  for _, path in ipairs(paths) do
    local stat = vim.uv.fs_stat(path)
    if not stat or stat.type ~= 'file' then return false end
  end

  vim.schedule(function()
    for _, path in ipairs(paths) do
      vim.cmd('edit ' .. vim.fn.fnameescape(path))
    end
  end)
  return true
end

--- 统一分发：先过注册的 handler，都没消费则走默认（打开文件）
---@param paths string[]
---@param pos vv-utils.drop.Position?
---@return boolean
function M.dispatch(paths, pos)
  for _, handler in ipairs(handlers) do
    if handler(paths, pos) then return true end
  end
  return default_handler(paths)
end

return M
