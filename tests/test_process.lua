local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local saved_system = vim.system
local systems = {}
local function drain()
  local drained = false
  vim.schedule(function() drained = true end)
  assert(vim.wait(100, function() return drained end, 1), '事件队列未能清空')
end

vim.system = function(command, opts, callback)
  local item = { command = command, opts = opts, callback = callback, kills = 0 }
  local process = {}
  function process:kill(signal)
    assert(signal == 'sigterm')
    item.kills = item.kills + 1
  end
  systems[#systems + 1] = item
  return process
end

package.loaded['vv-utils.process'] = nil
local Process = require('vv-utils.process')
local delivered = 0
local raw_exits = 0
local cancel_queued = Process.start({ 'tool' }, { text = true, on_raw_exit = function(result)
  raw_exits = raw_exits + 1
  assert(result.stdout == 'ok')
end }, function()
  delivered = delivered + 1
end)
assert(systems[1].opts.on_raw_exit == nil, '生命周期回调不得泄漏给 vim.system')
systems[1].callback({ code = 0, signal = 0, stdout = 'ok', stderr = '' })
cancel_queued()
cancel_queued()
drain()
assert(delivered == 0 and raw_exits == 1 and systems[1].kills == 0,
  '取消必须压制排队中的交付，但保留一次 raw-exit 通知且不能终止已完成进程')

local active_raw_exits = 0
local cancel_active = Process.start({ 'tool' }, { on_raw_exit = function()
  active_raw_exits = active_raw_exits + 1
end }, function() error('已取消进程仍然发布了结果') end)
cancel_active()
cancel_active()
assert(systems[2].kills == 1, '运行中的进程必须且只能被终止一次')
systems[2].callback({ code = 143, signal = 15, stdout = '', stderr = '' })
drain()
assert(active_raw_exits == 1, '取消后底层进程退出仍必须执行 raw-exit 清理')

vim.system = function() error('启动失败') end
package.loaded['vv-utils.process'] = nil
Process = require('vv-utils.process')
local failed
local raw_failed
local _, start_error = Process.start({ 'missing-tool' }, { on_raw_exit = function(result)
  raw_failed = result
end }, function(result)
  failed = result
end)
assert(start_error, '必须返回同步启动错误')
assert(vim.wait(100, function() return failed ~= nil end, 1), '必须异步交付启动失败结果')
assert(failed.code == -1 and failed.signal == 0 and failed.stderr:find('启动失败', 1, true),
  '启动失败结果必须保留原始错误')
assert(raw_failed == failed, '启动失败也必须经过一次 raw-exit 通知')

vim.system = saved_system
print('vv-utils process：通过')
