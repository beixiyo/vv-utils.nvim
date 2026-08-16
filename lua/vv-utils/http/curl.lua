-- 基于 curl 的非流式 HTTP transport

local Process = require('vv-utils.process')
local Fs = require('vv-utils.fs')
local Headers = require('vv-utils.http.headers')
local Temp = Fs.temp

local M = {}
local uv = vim.uv or vim.loop
local DEFAULT_TIMEOUT_MS = 15000

local function error_result(code, message, cause)
  return { code = code, message = message, cause = cause }
end

local function escape_config_string(value)
  return value:gsub('\\', '\\\\'):gsub('"', '\\"')
end

local function curl_binary()
  local uname = uv.os_uname()
  return uname and uname.sysname == 'Windows_NT' and 'curl.exe' or 'curl'
end

local function valid_method(method)
  return method:match('^[%a][%w!#$%%&%*%+%-.%^_`|~]*$') ~= nil
end

local function finite_positive(value)
  return type(value) == 'number'
    and value > 0
    and value ~= math.huge
    and value == value
end

local function read_temp(path)
  local ok, content = pcall(Fs.read_all, path)
  if ok then return content end
  return nil, content
end

---发起一次非流式 HTTP 请求
---@param opts vv-utils.http.RequestOptions
---@param callback fun(error: vv-utils.http.Error?, response: vv-utils.http.Response?)
---@return fun() cancel 幂等取消函数
function M.request(opts, callback)
  assert(type(opts) == 'table', 'opts must be a table')
  assert(type(callback) == 'function', 'callback must be a function')

  local paths = {}
  local state = 'active'
  local process_cancel

  local function finish(err, response)
    if state ~= 'active' then return end
    state = 'completed'
    Temp.cleanup(paths)
    callback(err, response)
  end

  local function cancel()
    if state ~= 'active' then return end
    state = 'cancelled'
    if process_cancel then pcall(process_cancel) end
    Temp.cleanup(paths)
  end

  local function invalid(message)
    finish(error_result('invalid_options', message))
    return cancel
  end

  if type(opts.url) ~= 'string' or opts.url == '' then
    return invalid('HTTP request URL is required')
  end
  if opts.url:find('[\r\n]') then
    return invalid('HTTP request URL is invalid')
  end

  local method = opts.method == nil and 'GET' or opts.method
  if type(method) ~= 'string' or method == '' or not valid_method(method) then
    return invalid('HTTP request method is invalid')
  end
  method = method:upper()

  local timeout_ms = opts.timeout_ms == nil and DEFAULT_TIMEOUT_MS or opts.timeout_ms
  if not finite_positive(timeout_ms) then
    return invalid('HTTP request timeout is invalid')
  end

  local body = opts.body
  if body ~= nil and type(body) ~= 'string' then
    return invalid('HTTP request body must be a string')
  end

  local headers = opts.headers
  if headers ~= nil and type(headers) ~= 'table' then
    return invalid('HTTP request headers must be a table')
  end

  local url_config_path = Temp.write('url = "' .. escape_config_string(opts.url) .. '"\n')
  if not url_config_path then
    return invalid('Failed to prepare HTTP request URL')
  end
  paths[#paths + 1] = url_config_path

  local header_path
  if headers then
    local header_text, header_error = Headers.serialize(headers)
    if not header_text then return invalid(header_error) end
    header_path = Temp.write(header_text)
    if not header_path then
      return invalid('Failed to prepare HTTP request headers')
    end
    paths[#paths + 1] = header_path
  end

  local body_path
  if body ~= nil then
    body_path = Temp.write(body)
    if not body_path then
      return invalid('Failed to prepare HTTP request body')
    end
    paths[#paths + 1] = body_path
  end

  local response_headers_path
  response_headers_path = Temp.create()
  if not response_headers_path then
    return invalid('Failed to prepare HTTP response headers')
  end
  paths[#paths + 1] = response_headers_path

  local response_body_path
  response_body_path = Temp.create()
  if not response_body_path then
    return invalid('Failed to prepare HTTP response body')
  end
  paths[#paths + 1] = response_body_path

  local command = {
    curl_binary(),
    '--silent',
    '--show-error',
    '--config',
    url_config_path,
    '--request',
    method,
    '--dump-header',
    response_headers_path,
    '--output',
    response_body_path,
    '--write-out',
    '%{http_code}',
    '--max-time',
    string.format('%.3f', math.max(timeout_ms / 1000, 0.001)),
  }

  if header_path then
    command[#command + 1] = '--header'
    command[#command + 1] = '@' .. header_path
  end
  if body_path then
    command[#command + 1] = '--data-binary'
    command[#command + 1] = '@' .. body_path
  end

  local function on_raw_exit()
    if state == 'cancelled' then Temp.cleanup(paths) end
  end

  local start_error
  process_cancel, start_error = Process.start(command, {
    text = true,
    on_raw_exit = on_raw_exit,
  }, function(result)
    if state ~= 'active' then return end

    if result.code == -1 then
      finish(error_result('start_failed', 'Failed to start curl', {
        message = 'curl process could not start',
      }))
      return
    end

    if result.code ~= 0 then
      local code = result.code == 28 and 'timeout' or 'process_failed'
      local message = result.code == 28 and 'HTTP request timed out' or 'HTTP request failed'
      finish(error_result(code, message, {
        exit_code = result.code,
        signal = result.signal,
      }))
      return
    end

    local status = tonumber(vim.trim(result.stdout or ''))
    local body_text, body_read_error = read_temp(response_body_path)
    local header_text, header_read_error = read_temp(response_headers_path)
    if not status or status < 100 or status > 599 then
      finish(error_result('invalid_response', 'HTTP response did not include a valid status', {
        body_error = body_read_error,
        headers_error = header_read_error,
      }))
      return
    end
    if not body_text or not header_text then
      finish(error_result('response_read_failed', 'Failed to read HTTP response', {
        body_error = body_read_error,
        headers_error = header_read_error,
      }))
      return
    end

    local response = {
      status = status,
      body = body_text,
      headers = Headers.parse(header_text),
    }
    if status < 200 or status >= 300 then
      finish(error_result('http_status', ('HTTP request returned status %d'):format(status), {
        status = status,
      }), response)
      return
    end

    finish(nil, response)
  end)

  -- Process.start 会把同步启动错误转成 code=-1 的异步结果；局部值仅用于
  -- 保持启动失败具备稳定 cause，不携带命令、请求头或请求体
  if not process_cancel and start_error then
    finish(error_result('start_failed', 'Failed to start curl', {
      message = 'curl process could not start',
    }))
  end

  return cancel
end

return M
