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
  local result
  Download.file({ url = 'https://example.invalid/file', destination = 'unused' }, function(value)
    result = value
  end)
  assert(result and result.code == 'downloader_not_found')
  assert(result.message:find('curl', 1, true))
end)

with_executables({ ['powershell.exe'] = true }, function()
  local captured
  vim.system = function(command, opts, callback)
    captured = { command = command, opts = opts }
    callback({ code = 0, stdout = '', stderr = '' })
  end

  local result
  Download.file({
    url = 'https://example.invalid/a b.exe',
    destination = 'C:/Temp/a b.exe',
  }, function(value)
    result = value
  end)
  vim.wait(1000, function() return result ~= nil end)

  assert(result and result.ok and result.backend == 'PowerShell')
  assert(captured.command[1] == 'powershell.exe')
  assert(captured.opts.env.VV_DOWNLOAD_URL == 'https://example.invalid/a b.exe')
  assert(captured.opts.env.VV_DOWNLOAD_DESTINATION == 'C:/Temp/a b.exe')
  assert(captured.opts.env.VV_DOWNLOAD_ATTEMPTS == '4')
end)

vim.system = original_system
print('vv-utils download test: ok')
