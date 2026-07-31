local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local Download = require('vv-utils.download')
local original_executable = vim.fn.executable
local original_system = vim.system

local function with_executables(available, callback)
  vim.fn.executable = function(command)
    return available[command] and 1 or 0
  end
  local ok, error = pcall(callback)
  vim.fn.executable = original_executable
  if not ok then error(error) end
end

with_executables({ curl = true, wget = true }, function()
  local resolved = assert(Download.resolve({ sysname = 'Darwin' }))
  assert(resolved.name == 'curl' and resolved.command == 'curl')
end)

with_executables({ wget = true }, function()
  local resolved = assert(Download.resolve({ sysname = 'Linux' }))
  assert(resolved.name == 'wget' and resolved.command == 'wget')
end)

with_executables({ ['powershell.exe'] = true, ['curl.exe'] = true, curl = true }, function()
  local resolved = assert(Download.resolve({ sysname = 'Windows_NT' }))
  assert(resolved.name == 'PowerShell' and resolved.command == 'powershell.exe')
end)

with_executables({ ['curl.exe'] = true, curl = true }, function()
  local resolved = assert(Download.resolve({ sysname = 'Windows_NT' }))
  assert(resolved.name == 'curl' and resolved.command == 'curl.exe')
end)

with_executables({}, function()
  local destination = vim.fn.tempname()
  vim.fn.writefile({ 'pre-existing' }, destination)
  local result
  local cancel = Download.file({
    url = 'https://example.invalid/file',
    destination = destination,
  }, function(value)
    result = value
  end)
  assert(result and result.code == 'downloader_not_found')
  assert(result.message:find('curl', 1, true))
  cancel()
  assert(vim.uv.fs_stat(destination),
    'cancel after synchronous failure delivery must not clean the destination')
  vim.fn.delete(destination)
end)

with_executables({ ['powershell.exe'] = true }, function()
  local captured
  vim.system = function(command, opts, callback)
    captured = { command = command, opts = opts }
    vim.fn.writefile({ 'powershell fixture' }, opts.env.VV_DOWNLOAD_DESTINATION)
    callback({ code = 0, stdout = '', stderr = '' })
  end

  local powershell_dir = vim.fn.tempname()
  local powershell_destination = vim.fs.joinpath(powershell_dir, 'a b.exe')
  vim.fn.mkdir(powershell_dir, 'p')
  local result
  Download.file({
    url = 'https://example.invalid/a b.exe',
    destination = powershell_destination,
  }, function(value)
    result = value
  end)
  vim.wait(1000, function() return result ~= nil end)

  assert(result and result.ok and result.backend == 'PowerShell')
  assert(captured.command[1] == 'powershell.exe')
  assert(captured.opts.env.VV_DOWNLOAD_URL == 'https://example.invalid/a b.exe')
  assert(captured.opts.env.VV_DOWNLOAD_DESTINATION ~= powershell_destination)
  assert(vim.fs.dirname(captured.opts.env.VV_DOWNLOAD_DESTINATION) == powershell_dir)
  assert(captured.opts.env.VV_DOWNLOAD_ATTEMPTS == '4')
  assert(table.concat(vim.fn.readfile(powershell_destination), '') == 'powershell fixture')
  vim.fn.delete(powershell_dir, 'rf')
end)

vim.system = original_system
local original_resolve = Download.resolve
local cancel_tmp = vim.fn.tempname()
local started_path = vim.fs.joinpath(cancel_tmp, 'started')
local destination = vim.fs.joinpath(cancel_tmp, 'download')
vim.fn.mkdir(cancel_tmp, 'p')
local cancel_staging
Download.resolve = function()
  return {
    name = 'fixture',
    command = '/bin/sh',
    build = function(_, _, target)
      cancel_staging = target
      return {
        '/bin/sh',
        '-c',
        'printf "%s" "$$" > "$1"; printf partial > "$2"; exec sleep 10',
        '_',
        started_path,
        target,
      }
    end,
  }
end

local callback_count = 0
local cancel = Download.file({
  url = 'https://example.invalid/cancel',
  destination = destination,
}, function()
  callback_count = callback_count + 1
end)
assert(type(cancel) == 'function', 'download must return a cancel function')
assert(vim.wait(1000, function() return vim.uv.fs_stat(started_path) ~= nil end),
  'fixture downloader did not start')
local pid = tonumber(table.concat(vim.fn.readfile(started_path), ''))
assert(vim.wait(1000, function() return vim.uv.fs_stat(cancel_staging) ~= nil end),
  'fixture downloader did not create its staging file before cancellation')
cancel()
cancel()
assert(vim.wait(1000, function() return vim.uv.kill(pid, 0) == nil end),
  'cancel must stop the real vim.system process')
vim.wait(50)
assert(callback_count == 0, 'cancelled downloads must suppress their callback')
assert(vim.uv.fs_stat(destination) == nil, 'cancelled download must not publish a partial destination')
assert(vim.uv.fs_stat(cancel_staging) == nil, 'cancel must remove its staging file')

local completed_destination = vim.fs.joinpath(cancel_tmp, 'completed-download')
vim.fn.writefile({ 'previous' }, completed_destination)
local last_success_staging
Download.resolve = function()
  return {
    name = 'fixture',
    command = '/bin/sh',
    build = function(_, _, target)
      last_success_staging = target
      return {
        '/bin/sh',
        '-c',
        'printf complete > "$1"',
        '_',
        target,
      }
    end,
  }
end

local completed_result
local cancel_completed = Download.file({
  url = 'https://example.invalid/completed',
  destination = completed_destination,
}, function(result)
  completed_result = result
end)
assert(vim.wait(1000, function() return completed_result ~= nil end),
  'real fixture download did not deliver its result')
assert(completed_result.ok, 'real fixture download should succeed')
cancel_completed()
cancel_completed()
assert(table.concat(vim.fn.readfile(completed_destination), '') == 'complete',
  'cancel after successful result delivery must preserve the destination')

local long_name_dir = vim.fs.joinpath(cancel_tmp, 'long-name')
vim.fn.mkdir(long_name_dir)
local long_destination = vim.fs.joinpath(long_name_dir, string.rep('a', 230))
vim.fn.writefile({ 'previous' }, long_destination)
local long_name_result
Download.file({
  url = 'https://example.invalid/long-name',
  destination = long_destination,
}, function(result)
  long_name_result = result
end)
assert(vim.wait(1000, function() return long_name_result ~= nil end),
  'long destination fixture did not deliver its result')
assert(long_name_result.ok, 'legal long destination basename must remain downloadable')
assert(#vim.fs.basename(last_success_staging) < 255,
  'staging basename must stay independent of destination basename length')
assert(table.concat(vim.fn.readfile(long_destination), '') == 'complete',
  'long destination did not receive the completed download')

local blocked_destination = vim.fs.joinpath(cancel_tmp, 'blocked-destination')
vim.fn.mkdir(blocked_destination)
vim.fn.writefile({ 'owned' }, vim.fs.joinpath(blocked_destination, 'child'))
local blocked_result
Download.file({
  url = 'https://example.invalid/publish-failure',
  destination = blocked_destination,
}, function(result)
  blocked_result = result
end)
assert(vim.wait(1000, function() return blocked_result ~= nil end),
  'publish failure fixture did not deliver its result')
assert(not blocked_result.ok and blocked_result.code == 'publish_failed',
  'failed atomic publish must report publish_failed')
assert(table.concat(vim.fn.readfile(vim.fs.joinpath(blocked_destination, 'child')), '') == 'owned',
  'failed atomic publish modified the existing destination')
assert(vim.uv.fs_stat(last_success_staging) == nil,
  'failed atomic publish left its staging file behind')

local shared_destination = vim.fs.joinpath(cancel_tmp, 'shared-download')
local shared_a_started = vim.fs.joinpath(cancel_tmp, 'shared-a-started')
local shared_b_started = vim.fs.joinpath(cancel_tmp, 'shared-b-started')
local shared_calls = 0
local shared_staging = {}
Download.resolve = function()
  return {
    name = 'fixture',
    command = '/bin/sh',
    build = function(_, _, target)
      shared_calls = shared_calls + 1
      shared_staging[#shared_staging + 1] = target
      if shared_calls == 1 then
        return {
          '/bin/sh',
          '-c',
          [[
printf old-partial > "$1"
printf "%s" "$$" > "$2"
trap 'sleep 0.25; exit 143' TERM
while :; do sleep 0.05; done
]],
          '_',
          target,
          shared_a_started,
        }
      end
      return {
        '/bin/sh',
        '-c',
        'printf new-complete > "$1"; printf started > "$2"; sleep 0.6',
        '_',
        target,
        shared_b_started,
      }
    end,
  }
end

local old_callback_count = 0
local cancel_old = Download.file({
  url = 'https://example.invalid/shared-a',
  destination = shared_destination,
}, function()
  old_callback_count = old_callback_count + 1
end)
assert(vim.wait(1000, function()
  return vim.uv.fs_stat(shared_a_started) ~= nil
    and shared_staging[1]
    and vim.uv.fs_stat(shared_staging[1]) ~= nil
end), 'old shared download did not create its staging file')
local old_pid = tonumber(table.concat(vim.fn.readfile(shared_a_started), ''))
cancel_old()

local new_result
Download.file({
  url = 'https://example.invalid/shared-b',
  destination = shared_destination,
}, function(result)
  new_result = result
end)
assert(vim.wait(1000, function()
  return vim.uv.fs_stat(shared_b_started) ~= nil
    and shared_staging[2]
    and vim.uv.fs_stat(shared_staging[2]) ~= nil
end), 'new shared download did not create its staging file')
assert(vim.uv.kill(old_pid, 0) ~= nil,
  'old shared download exited before the new download started')
assert(vim.wait(2000, function() return new_result ~= nil end),
  'new shared download did not deliver its result')
assert(new_result.ok, 'new shared download should succeed')
assert(vim.wait(1000, function() return vim.uv.kill(old_pid, 0) == nil end),
  'cancelled old shared download did not exit')
assert(old_callback_count == 0, 'cancelled old shared download delivered a callback')
assert(shared_staging[1] ~= shared_staging[2],
  'downloads that share a destination must own different staging files')
assert(table.concat(vim.fn.readfile(shared_destination), '') == 'new-complete',
  'old cancellation cleanup removed the new download destination')
assert(vim.uv.fs_stat(shared_staging[1]) == nil
    and vim.uv.fs_stat(shared_staging[2]) == nil,
  'shared downloads left staging files behind')

Download.resolve = original_resolve
vim.fn.delete(cancel_tmp, 'rf')
vim.system = original_system
print('vv-utils download test: ok')
