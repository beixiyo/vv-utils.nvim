---跨平台 tar 归档读取与解压
---
---本模块只负责归档机制，不决定下载、版本、校验或安装发布策略
local M = {}
local Callback = require('vv-utils.callback')
local Process = require('vv-utils.process')
local fs = require('vv-utils.fs')

local DEFAULT_COMMANDS = { 'tar', 'bsdtar' }

local function schedule(callback, value)
  vim.schedule(function() callback(value) end)
end

---返回首个可用的 tar 实现
---@param commands? string[] 候选命令，按顺序检查 @default { 'tar', 'bsdtar' }
---@return string? command
function M.resolve(commands)
  for _, command in ipairs(commands or DEFAULT_COMMANDS) do
    if vim.fn.executable(command) == 1 then return command end
  end
end

---校验归档成员路径，防止绝对路径、父目录逃逸和 Windows ADS
---@param entries string[]
---@return boolean ok
---@return { entry: string, reason: string }? unsafe
function M.validate(entries)
  for _, entry in ipairs(entries) do
    local normalized = entry:gsub('\\', '/')

    if normalized:sub(1, 1) == '/' then
      return false, { entry = entry, reason = 'absolute_path' }
    end

    if normalized:match('^%a:') then
      return false, { entry = entry, reason = 'drive_path' }
    end

    if normalized:find(':', 1, true) then
      return false, { entry = entry, reason = 'alternate_data_stream' }
    end

    for component in normalized:gmatch('[^/]+') do
      if component == '..' then
        return false, { entry = entry, reason = 'parent_traversal' }
      end
    end
  end
  return true
end

local function run(command, args, callback)
  local argv = { command }
  vim.list_extend(argv, args)
  return Process.start(argv, { text = true }, callback)
end

---异步列出 tar 归档成员
---@param opts vv-utils.archive.ListOptions
---@param callback fun(result: vv-utils.archive.ListResult)
---@return fun() cancel 停止进程并压制尚未投递的 callback，幂等
function M.list(opts, callback)
  local finish, cancel_callback = Callback.limit(callback)
  local cancelled = false
  local cancel_process

  local function cancel()
    if cancelled then return end
    cancelled = true
    cancel_callback()
    if cancel_process then cancel_process() end
  end

  if not fs.exists(opts.archive) then
    schedule(finish, {
      ok = false,
      code = 'archive_not_found',
      message = 'Archive does not exist: ' .. opts.archive,
    })
    return cancel
  end

  local command = M.resolve(opts.commands)
  if not command then
    schedule(finish, {
      ok = false,
      code = 'archiver_not_found',
      message = 'No tar tool found. Install tar or bsdtar and try again',
      attempted = opts.commands or vim.deepcopy(DEFAULT_COMMANDS),
    })
    return cancel
  end

  cancel_process = run(command, { '-tf', opts.archive }, function(completed)
    if completed.code ~= 0 then
      local detail = completed.stderr ~= '' and completed.stderr or completed.stdout
      finish({
        ok = false,
        code = 'list_failed',
        message = vim.trim(detail or ('exit code ' .. completed.code)),
        backend = command,
        exitCode = completed.code,
      })
      return
    end

    local entries = vim.split(completed.stdout or '', '\n', { plain = true, trimempty = true })
    finish({ ok = true, backend = command, entries = entries })
  end)
  return cancel
end

---异步安全解压 tar 归档到已存在的空目录
---@param opts vv-utils.archive.ExtractOptions
---@param callback fun(result: vv-utils.archive.ExtractResult)
---@return fun() cancel 停止当前阶段并压制尚未投递的 callback，幂等
function M.extract(opts, callback)
  local finish, cancel_callback = Callback.limit(callback)
  local cancelled = false
  local cancel_phase

  local function cancel()
    if cancelled then return end
    cancelled = true
    cancel_callback()
    if cancel_phase then cancel_phase() end
  end

  if not fs.is_directory(opts.destination) then
    schedule(finish, {
      ok = false,
      code = 'destination_not_found',
      message = 'Destination directory does not exist: ' .. opts.destination,
    })
    return cancel
  end

  local empty, read_error = fs.is_dir_empty(opts.destination)
  if empty == nil then
    schedule(finish, { ok = false, code = 'destination_unreadable', message = tostring(read_error) })
    return cancel
  end
  if not empty then
    schedule(finish, {
      ok = false,
      code = 'destination_not_empty',
      message = 'Destination directory must be empty: ' .. opts.destination,
    })
    return cancel
  end

  cancel_phase = M.list({ archive = opts.archive, commands = opts.commands }, function(list_result)
    if cancelled then return end
    if not list_result.ok then
      finish(list_result)
      return
    end

    local safe, unsafe = M.validate(list_result.entries)
    if not safe then
      finish({
        ok = false,
        code = 'unsafe_entry',
        message = 'Unsafe archive entry: ' .. unsafe.entry,
        backend = list_result.backend,
        entry = unsafe.entry,
        reason = unsafe.reason,
      })
      return
    end

    cancel_phase = run(list_result.backend, { '-xf', opts.archive, '-C', opts.destination }, function(completed)
      if completed.code == 0 then
        finish({ ok = true, backend = list_result.backend, entries = list_result.entries })
        return
      end
      local detail = completed.stderr ~= '' and completed.stderr or completed.stdout
      finish({
        ok = false,
        code = 'extract_failed',
        message = vim.trim(detail or ('exit code ' .. completed.code)),
        backend = list_result.backend,
        exitCode = completed.code,
      })
    end)
  end)
  return cancel
end

---@class vv-utils.archive.ListOptions
---@field archive string 归档文件路径
---@field commands? string[] tar 候选命令 @default { 'tar', 'bsdtar' }

---@class vv-utils.archive.ExtractOptions: vv-utils.archive.ListOptions
---@field destination string 已存在且为空的目标目录

---@class vv-utils.archive.ListResult
---@field ok boolean
---@field code? 'archive_not_found'|'archiver_not_found'|'list_failed'
---@field message? string
---@field backend? string
---@field attempted? string[]
---@field entries? string[]
---@field exitCode? integer

---@class vv-utils.archive.ExtractResult: vv-utils.archive.ListResult
---@field code? 'archive_not_found'|'archiver_not_found'|'list_failed'|'destination_not_found'|'destination_unreadable'|'destination_not_empty'|'unsafe_entry'|'extract_failed'
---@field entry? string
---@field reason? string

return M
