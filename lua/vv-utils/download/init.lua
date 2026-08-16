---跨平台文件下载：自动选择 curl、wget 或 PowerShell
---
---本模块只负责把 URL 下载到指定路径，不决定资源版本、安装目录或更新策略
local Process = require('vv-utils.process')

local M = {}
local download_sequence = 0

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

local function next_staging_path(destination)
  download_sequence = download_sequence + 1
  local token = table.concat({
    tostring(vim.fn.getpid()),
    tostring(vim.uv.hrtime()),
    tostring(download_sequence),
  }, '-')
  return vim.fs.joinpath(vim.fs.dirname(destination), '.vv-download-' .. token)
end

---异步下载文件
---每个请求写入同目录独占 staging，成功后原子替换 destination；取消只清理 staging
---@param opts vv-utils.download.Options
---@param callback fun(result: vv-utils.download.Result)
---@return fun() cancel 停止下载并压制尚未投递的 callback，幂等
function M.file(opts, callback)
  local state = 'active'
  local process_cancel
  local staging = next_staging_path(opts.destination)
  local function cleanup_staging()
    pcall(vim.uv.fs_unlink, staging)
  end

  local function cancel()
    if state ~= 'active' then return end
    state = 'cancelled'
    if process_cancel then pcall(process_cancel) end
    cleanup_staging()
  end

  local function finish(result)
    if state ~= 'active' then return end
    state = 'completed'
    callback(result)
  end

  local downloader = M.resolve()
  if not downloader then
    finish({
      ok = false,
      code = 'downloader_not_found',
      message = 'No download tool found. Install curl, wget, or PowerShell and try again',
      attempted = { 'curl', 'wget', 'pwsh', 'powershell.exe' },
    })
    return cancel
  end

  local retries = opts.retries == nil and 3 or opts.retries
  local command = downloader.build(downloader.command, opts.url, staging, retries)
  local system_opts = {
    text = true,
    env = downloader.env and downloader.env(opts.url, staging, retries) or nil,
    on_raw_exit = function()
      -- 交付 callback 会在取消后被 process 压制；raw exit 仍必须补做一次清理
      if state == 'cancelled' then cleanup_staging() end
    end,
  }

  local start_error
  process_cancel, start_error = Process.start(command, system_opts, function(completed)
    if state == 'cancelled' then
      cleanup_staging()
      return
    end

    if completed.code == 0 then
      local published, publish_error = vim.uv.fs_rename(staging, opts.destination)
      if not published then
        cleanup_staging()
        finish({
          ok = false,
          code = 'publish_failed',
          message = 'Failed to publish download: ' .. tostring(publish_error),
          backend = downloader.name,
        })
        return
      end
      finish({ ok = true, backend = downloader.name })
      return
    end

    cleanup_staging()
    local detail = completed.stderr ~= '' and completed.stderr or completed.stdout
    local failure = {
      ok = false,
      code = 'download_failed',
      message = vim.trim(detail or (start_error and tostring(start_error) or ('exit code ' .. completed.code))),
      backend = downloader.name,
    }
    if not start_error then failure.exitCode = completed.code end
    finish(failure)
  end)
  return cancel
end

---@class vv-utils.download.Options
---@field url string 下载地址
---@field destination string 成功后原子替换的最终路径
---@field retries? integer 下载器重试次数 @default 3

---@class vv-utils.download.Result
---@field ok boolean 下载是否成功
---@field code? 'downloader_not_found'|'download_failed'|'publish_failed' 失败类型
---@field message? string 可直接展示给用户的失败原因
---@field backend? string 实际使用的下载器
---@field attempted? string[] 未找到下载器时检查过的命令
---@field exitCode? integer 下载命令退出码

return M
