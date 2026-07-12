---跨平台文件下载：自动选择 curl、wget 或 PowerShell
---
---本模块只负责把 URL 下载到指定路径，不决定资源版本、安装目录或更新策略
local M = {}

local CURL = {
  name = 'curl',
  commands = { 'curl' },
  build = function(command, url, destination, retries)
    return {
      command,
      '--fail',
      '--location',
      '--retry',
      tostring(retries),
      '--output',
      destination,
      url,
    }
  end,
}

local WINDOWS_CURL = vim.tbl_extend('force', CURL, { commands = { 'curl.exe' } })

local WGET = {
  name = 'wget',
  commands = { 'wget' },
  build = function(command, url, destination, retries)
    return {
      command,
      '--tries=' .. tostring(retries + 1),
      '--output-document=' .. destination,
      url,
    }
  end,
}

local POWERSHELL = {
  name = 'PowerShell',
  commands = { 'pwsh', 'powershell.exe', 'powershell' },
  build = function(command)
    return {
      command,
      '-NoLogo',
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      [[
$ErrorActionPreference = 'Stop'
$attempts = [int]$env:VV_DOWNLOAD_ATTEMPTS
for ($attempt = 1; $attempt -le $attempts; $attempt++) {
  try {
    Invoke-WebRequest -UseBasicParsing -Uri $env:VV_DOWNLOAD_URL -OutFile $env:VV_DOWNLOAD_DESTINATION
    exit 0
  } catch {
    if ($attempt -eq $attempts) { throw }
    Start-Sleep -Seconds 1
  }
}
]],
    }
  end,
  env = function(url, destination, retries)
    return {
      VV_DOWNLOAD_URL = url,
      VV_DOWNLOAD_DESTINATION = destination,
      VV_DOWNLOAD_ATTEMPTS = tostring(retries + 1),
    }
  end,
}

local UNIX_DOWNLOADERS = {
  CURL,
  WGET,
  POWERSHELL,
}

local WINDOWS_DOWNLOADERS = {
  POWERSHELL,
  WINDOWS_CURL,
  WGET,
}

local function find_command(commands)
  for _, command in ipairs(commands) do
    if vim.fn.executable(command) == 1 then return command end
  end
end

---返回当前平台首选的可用下载器
---Windows 显式优先 PowerShell，再检查 curl.exe，避免把 PowerShell 的 curl alias 当作 curl CLI
---@param uname? table uv.os_uname() 兼容结构
---@return { name: string, command: string, build: function, env?: function }? downloader
function M.resolve(uname)
  local system = (uname or vim.uv.os_uname()).sysname
  local candidates = system == 'Windows_NT' and WINDOWS_DOWNLOADERS or UNIX_DOWNLOADERS
  for _, candidate in ipairs(candidates) do
    local command = find_command(candidate.commands)
    if command then
      return {
        name = candidate.name,
        command = command,
        build = candidate.build,
        env = candidate.env,
      }
    end
  end
end

---异步下载文件
---@param opts { url: string, destination: string, retries?: integer }
---@param callback fun(result: vv-utils.download.Result)
function M.file(opts, callback)
  local downloader = M.resolve()
  if not downloader then
    callback({
      ok = false,
      code = 'downloader_not_found',
      message = 'No download tool found. Install curl, wget, or PowerShell and try again',
      attempted = { 'curl', 'wget', 'pwsh', 'powershell.exe' },
    })
    return
  end

  local retries = opts.retries == nil and 3 or opts.retries
  local command = downloader.build(downloader.command, opts.url, opts.destination, retries)
  local system_opts = {
    text = true,
    env = downloader.env and downloader.env(opts.url, opts.destination, retries) or nil,
  }

  local started, start_error = pcall(vim.system, command, system_opts, function(completed)
    vim.schedule(function()
      if completed.code == 0 then
        callback({ ok = true, backend = downloader.name })
        return
      end

      local detail = completed.stderr ~= '' and completed.stderr or completed.stdout
      callback({
        ok = false,
        code = 'download_failed',
        message = vim.trim(detail or ('exit code ' .. completed.code)),
        backend = downloader.name,
        exitCode = completed.code,
      })
    end)
  end)
  if not started then
    callback({
      ok = false,
      code = 'download_failed',
      message = tostring(start_error),
      backend = downloader.name,
    })
  end
end

---@class vv-utils.download.Result
---@field ok boolean 下载是否成功
---@field code? 'downloader_not_found'|'download_failed' 失败类型
---@field message? string 可直接展示给用户的失败原因
---@field backend? string 实际使用的下载器
---@field attempted? string[] 未找到下载器时检查过的命令
---@field exitCode? integer 下载命令退出码

return M
