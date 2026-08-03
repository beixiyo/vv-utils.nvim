-- vv-utils.sys 的 Niri latest-wins 与辅助资源取消回归

local this = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
local plugin_root = vim.fn.fnamemodify(this, ':h:h')
vim.opt.runtimepath:prepend(plugin_root)

local original_open = vim.ui.open
local original_system = vim.system
local original_defer = vim.defer_fn
local original_socket = vim.env.NIRI_SOCKET

local calls = {}
local timers = {}
local focused = {}

vim.env.NIRI_SOCKET = 'test-socket'
vim.ui.open = function() return {} end
vim.defer_fn = function(callback)
  local timer = { callback = callback, closing = false, stopped = false }
  function timer:is_closing() return self.closing end
  function timer:stop() self.stopped = true end
  function timer:close() self.closing = true end
  timers[#timers + 1] = timer
  return timer
end
vim.system = function(command, _, callback)
  if command[3] == 'action' then
    focused[#focused + 1] = command[#command]
    return { kill = function() end }
  end

  local call = { command = command, callback = callback, killed = false }
  function call:kill() self.killed = true end
  calls[#calls + 1] = call
  return call
end

package.loaded['vv-utils.sys'] = nil
local Sys = require('vv-utils.sys')

assert(Sys.open_default('/tmp/A.txt'))
calls[1].callback({ code = 0, stdout = 'text/plain\n' })
calls[2].callback({ code = 0, stdout = 'app-a.desktop\n' })
timers[1].callback()
local a_windows = calls[3]

assert(Sys.open_default('/tmp/B.txt'))
assert(a_windows.killed and timers[1].closing,
  '打开 B 时应取消 A 的在途窗口查询并关闭 A 的轮询 timer')
calls[4].callback({ code = 0, stdout = 'text/plain\n' })
calls[5].callback({ code = 0, stdout = 'app-b.desktop\n' })
timers[2].callback()
local b_windows = calls[6]

b_windows.callback({
  code = 0,
  stdout = vim.json.encode({
    { id = 22, app_id = 'app-b', title = 'B.txt', is_focused = false },
  }),
})
a_windows.callback({
  code = 0,
  stdout = vim.json.encode({
    { id = 11, app_id = 'app-a', title = 'A.txt', is_focused = false },
  }),
})

assert(#focused == 1 and focused[1] == '22',
  '旧 A callback 即使已进入事件队列也不能在 B 之后抢回焦点')

local sync_processes = {}
local sync_timer
vim.system = function(command, _, callback)
  if command[3] == 'action' then return { kill = function() end } end
  local process = { killed = false }
  function process:kill() self.killed = true end
  sync_processes[#sync_processes + 1] = process
  if command[3] == 'filetype' then
    callback({ code = 0, stdout = 'text/plain\n' })
  elseif command[3] == 'default' then
    callback({ code = 0, stdout = 'sync-app.desktop\n' })
  elseif command[3] == '--json' then
    callback({
      code = 0,
      stdout = vim.json.encode({
        { id = 33, app_id = 'sync-app', title = 'sync.txt', is_focused = false },
      }),
    })
  end
  return process
end
vim.defer_fn = function(callback)
  local timer = { closing = false, stopped = false }
  function timer:is_closing() return self.closing end
  function timer:stop() self.stopped = true end
  function timer:close() self.closing = true end
  callback()
  sync_timer = timer
  return timer
end
assert(Sys.open_default('/tmp/sync.txt'))
assert(sync_timer.closing, '同步完成后才返回的 timer handle 应立即释放')
for _, process in ipairs(sync_processes) do
  assert(not process.killed, '正常同步完成后才返回的 process handle 不应被当作取消而 kill')
end

local late_cancel_processes = {}
local opening_replacement = false
vim.defer_fn = function()
  local timer = { closing = false }
  function timer:is_closing() return self.closing end
  function timer:stop() end
  function timer:close() self.closing = true end
  return timer
end
vim.system = function(command, _, callback)
  if command[3] == 'action' then return { kill = function() end } end
  local process = { killed = false }
  function process:kill() self.killed = true end
  late_cancel_processes[#late_cancel_processes + 1] = process

  if command[3] == 'filetype' and not opening_replacement then
    callback({ code = 0, stdout = 'text/plain\n' })
  elseif command[3] == 'default' and not opening_replacement then
    opening_replacement = true
    assert(Sys.open_default('/tmp/replacement.txt'))
  end
  return process
end
assert(Sys.open_default('/tmp/late-cancel.txt'))
assert(late_cancel_processes[1].killed and late_cancel_processes[2].killed,
  '取消先发生时，随后返回的 helper process handle 必须立即 kill')

vim.ui.open = original_open
vim.system = original_system
vim.defer_fn = original_defer
vim.env.NIRI_SOCKET = original_socket

print('[PASS] vv-utils.sys Niri request scope lifecycle')
