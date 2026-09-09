-- 状态文件变更监听：同一进程内按路径共享目录级 fs_event

local Fs = require('vv-utils.fs')

local uv = vim.uv or vim.loop
local M = {}
local watches = {}
local next_id = 0

---@class VVStateFileWatch
---@field basename string
---@field watcher uv.uv_fs_event_t
---@field subscribers table<integer, fun()>

---@param path string
---@param callback fun()
---@return fun() unsubscribe
function M.subscribe(path, callback)
  path = Fs.realpath(path)
  local entry = watches[path]

  if not entry then
    local directory = vim.fs.dirname(path)
    Fs.mkdir_p(directory)

    local watcher = assert(uv.new_fs_event(), 'failed to create state file watcher')
    entry = {
      basename = vim.fs.basename(path),
      watcher = watcher,
      subscribers = {},
    }

    local started, start_error = watcher:start(directory, {}, function(error_message, filename)
      if error_message then
        vim.schedule(function()
          vim.notify('vv-utils.state: file watcher failed: ' .. tostring(error_message), vim.log.levels.ERROR)
        end)
        return
      end

      if filename and vim.fs.basename(filename) ~= entry.basename then return end
      for _, subscriber in pairs(entry.subscribers) do subscriber() end
    end)
    if not started then
      watcher:close()
      error('failed to watch state file: ' .. path .. ' — ' .. tostring(start_error))
    end
    watches[path] = entry
  end

  next_id = next_id + 1
  local id = next_id
  entry.subscribers[id] = callback
  local active = true

  return function()
    if not active then return end
    active = false
    entry.subscribers[id] = nil
    if next(entry.subscribers) then return end

    watches[path] = nil
    if not entry.watcher:is_closing() then
      entry.watcher:stop()
      entry.watcher:close()
    end
  end
end

return M
