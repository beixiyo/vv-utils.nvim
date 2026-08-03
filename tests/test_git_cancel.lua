local this = debug.getinfo(1, 'S').source:sub(2)
local plugin_root = vim.fn.fnamemodify(this, ':p:h:h')
package.path = table.concat({
  plugin_root .. '/lua/?.lua',
  plugin_root .. '/lua/?/init.lua',
  package.path,
}, ';')

local saved_system = vim.system
local systems = {}
vim.system = function(command, opts, handler)
  local item = { command = command, opts = opts, handler = handler, kills = 0 }
  local process = {}
  function process:kill(signal)
    assert(signal == 'sigterm')
    item.kills = item.kills + 1
  end
  item.process = process
  systems[#systems + 1] = item
  return process
end

local function drain()
  local sentinel = false
  vim.schedule(function() sentinel = true end)
  assert(vim.wait(100, function() return sentinel end, 1),
    'scheduled callback fixture did not drain the event queue')
end

package.loaded['vv-utils.git.status'] = nil
local Status = require('vv-utils.git.status')
local status_callbacks = 0
local cancel_index = Status.index('/repo', function() status_callbacks = status_callbacks + 1 end)
systems[1].handler({ code = 0, stdout = '' })
cancel_index()
cancel_index()
drain()
assert(systems[1].kills == 0 and status_callbacks == 0,
  'completed index producer was killed or queued callback escaped')

local cancel_tracked = Status.tracked('/repo', function() status_callbacks = status_callbacks + 1 end)
systems[2].handler({ code = 0, stdout = 'a.lua\0' })
cancel_tracked()
local cancel_ignored = Status.ignored_entries('/repo', function() status_callbacks = status_callbacks + 1 end)
systems[3].handler({ code = 0, stdout = 'build/\0' })
cancel_ignored()
drain()
assert(systems[2].kills == 0 and systems[3].kills == 0 and status_callbacks == 0,
  'completed tracked/ignored producer was killed or leaked queued delivery')

package.loaded['vv-utils.git.repository'] = nil
local Repository = require('vv-utils.git.repository')
local roots = 0
local cancel_root = Repository.root_async('/repo', function() roots = roots + 1 end)
systems[4].handler({ code = 0, stdout = '/repo\n' })
cancel_root()
drain()
assert(systems[4].kills == 0 and roots == 0,
  'completed root producer was killed or leaked queued delivery')

package.loaded['vv-utils.git.diff'] = nil
local Diff = require('vv-utils.git.diff')
local diff_callbacks = 0
local cancel_sets = Diff.diff_line_sets('a.lua', function() diff_callbacks = diff_callbacks + 1 end, {
  root = '/repo',
})
assert(#systems == 6, 'diff_line_sets did not start both producers')
systems[5].handler({ code = 0, stdout = '@@ -1 +1 @@\n' })
systems[6].handler({ code = 0, stdout = '@@ -1 +1 @@\n' })
cancel_sets()
cancel_sets()
drain()
assert(systems[5].kills == 0 and systems[6].kills == 0 and diff_callbacks == 0,
  'completed combined diff producers were killed or leaked queued delivery')

local root_cancelled = 0
package.loaded['vv-utils.git.repository'] = {
  root_async = function(_, callback)
    callback('/repo')
    return function() root_cancelled = root_cancelled + 1 end
  end,
}
package.loaded['vv-utils.git.diff'] = nil
Diff = require('vv-utils.git.diff')
local temp = vim.fn.tempname()
vim.fn.writefile({ 'x' }, temp)
local cancel_lines = Diff.diff_lines(temp, function() diff_callbacks = diff_callbacks + 1 end)
assert(#systems == 7, 'diff_lines did not survive synchronous root callback before cancel handle return')
systems[7].handler({ code = 0, stdout = '@@ -1 +1 @@\n' })
cancel_lines()
drain()
assert(root_cancelled == 1 and systems[7].kills == 0 and diff_callbacks == 0,
  'late root cancel handle was lost or completed diff producer was killed')
vim.fn.delete(temp)

-- 物理取消仍会终止尚未进入原始回调的 producer
local cancel_active_index = Status.index('/repo', function() error('cancelled index published') end)
cancel_active_index()
assert(systems[8].kills == 1, 'active index producer was not physically cancelled')

package.loaded['vv-utils.git.repository'] = nil
Repository = require('vv-utils.git.repository')
local cancel_active_root = Repository.root_async('/repo', function() error('cancelled root published') end)
cancel_active_root()
assert(systems[9].kills == 1, 'active root producer was not physically cancelled')

package.loaded['vv-utils.git.diff'] = nil
Diff = require('vv-utils.git.diff')
local cancel_active_sets = Diff.diff_line_sets('a.lua', function() error('cancelled diff published') end, {
  root = '/repo',
})
cancel_active_sets()
assert(systems[10].kills == 1 and systems[11].kills == 1,
  'active combined diff producers were not physically cancelled')

-- 复合 helper 的第二个 producer 构造抛错时会回滚第一个 producer
local spawn_count = 0
local first_spawn = { kills = 0 }
function first_spawn:kill(signal)
  assert(signal == 'sigterm')
  self.kills = self.kills + 1
end
vim.system = function(_, _, handler)
  spawn_count = spawn_count + 1
  if spawn_count == 2 then error('injected second diff spawn failure') end
  first_spawn.handler = handler
  return first_spawn
end
local construction_result = 'pending'
local construction_ok, construction_cancel = pcall(Diff.diff_line_sets, 'a.lua', function(value)
  construction_result = value
end, { root = '/repo' })
assert(construction_ok and type(construction_cancel) == 'function',
  'diff_line_sets leaked a construction error across its async API')
assert(first_spawn.kills == 1, 'second diff spawn failure did not roll back the first producer')
assert(vim.wait(100, function() return construction_result ~= 'pending' end, 1),
  'diff construction failure did not complete its callback')
assert(construction_result == nil, 'diff construction failure published a result')

vim.system = function() error('injected index spawn failure') end
package.loaded['vv-utils.git.process'] = nil
local Process = require('vv-utils.git.process')
local process_result
local _, process_start_error = Process.start({ 'git', 'status' }, {}, function(result)
  process_result = result
end)
assert(process_start_error, 'process helper must return the synchronous spawn error')
assert(vim.wait(100, function() return process_result ~= nil end, 1),
  'process helper did not deliver its synthetic completion')
assert(process_result.code == -1 and process_result.signal == 0,
  'synthetic SystemCompleted must provide code and signal')
assert(process_result.stderr:find('injected index spawn failure', 1, true),
  'synthetic SystemCompleted must retain the spawn error')

local single_result = 'pending'
local single_ok, single_cancel = pcall(Status.index, '/repo', function(value)
  single_result = value
end)
assert(single_ok and type(single_cancel) == 'function',
  'single-producer helper leaked a spawn error across its async API')
assert(vim.wait(100, function() return single_result ~= 'pending' end, 1),
  'single-producer spawn failure did not complete its callback')
assert(single_result == nil, 'single-producer spawn failure published a result')

vim.system = saved_system
print('PASS: git helpers expose idempotent physical cancellation and suppress queued callbacks')
