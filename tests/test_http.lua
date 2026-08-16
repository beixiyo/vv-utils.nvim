local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local Http = require('vv-utils.http')

assert(Http.encode_query_component('a b+c&中文/你好') == 'a%20b%2Bc%26%E4%B8%AD%E6%96%87%2F%E4%BD%A0%E5%A5%BD',
  'query component 必须只保留 RFC 3986 unreserved 字符')
assert(Http.append_query('https://example.test/path', {
  z = 'last value',
  a = 'first',
  omitted = nil,
  enabled = true,
  count = 2,
}) == 'https://example.test/path?a=first&count=2&enabled=true&z=last%20value',
  'query 参数必须稳定排序并省略 nil')
assert(Http.append_query('https://example.test/path?old=1', { q = 'x' })
  == 'https://example.test/path?old=1&q=x')
assert(Http.append_query('https://example.test/path?', { q = 'x' })
  == 'https://example.test/path?q=x')
assert(Http.append_query('https://example.test/path?old=1&', { q = 'x' })
  == 'https://example.test/path?old=1&q=x')
assert(Http.append_query('https://example.test/path#section', { q = 'x' })
  == 'https://example.test/path?q=x#section')

local original_system = vim.system
local captured
local systems = {}
vim.system = function(command, opts, callback)
  captured = { command = command, opts = opts, callback = callback }
  systems[#systems + 1] = captured
  return {
    kill = function()
      captured.killed = true
    end,
  }
end

local result_error
local result_response
Http.request({
  url = 'https://secret.example.test/path?q=private',
  method = 'POST',
  headers = { Authorization = 'Bearer secret-header' },
  body = 'secret-body',
}, function(err, response)
  result_error = err
  result_response = response
end)

assert(captured, 'request 必须启动异步 curl 进程')
local command_text = table.concat(captured.command, '\0')
assert(not command_text:find('secret', 1, true), '敏感 URL、header、body 不得出现在 argv')
assert(captured.command[1] == 'curl', 'Unix 请求必须使用 curl')

local function argument_after(argument)
  for index, value in ipairs(captured.command) do
    if value == argument then return captured.command[index + 1] end
  end
end

local body_path = argument_after('--output')
local headers_path = argument_after('--dump-header')
assert(body_path and headers_path, 'curl 必须使用预创建的响应文件')
assert(vim.uv.fs_stat(argument_after('--config')).mode % 4096 == 384,
  'HTTP 临时文件必须仅允许当前用户读写')
vim.fn.writefile({ 'response-body' }, body_path)
vim.fn.writefile({
  'HTTP/1.1 200 OK',
  'Content-Type: application/json',
  'X-Trace: first',
  'X-Trace: second',
  '',
}, headers_path)
captured.callback({ code = 0, signal = 0, stdout = '200', stderr = '' })
assert(vim.wait(100, function() return result_response ~= nil end, 1), '响应回调必须异步交付')

assert(result_error == nil and result_response.status == 200)
assert(result_response.body == 'response-body\n')
assert(result_response.headers['content-type'] == 'application/json')
assert(result_response.headers['x-trace'] == 'first, second')
assert(vim.uv.fs_stat(body_path) == nil and vim.uv.fs_stat(headers_path) == nil,
  '请求完成后必须清理响应临时文件')

local cancelled_callback = 0
local cancel = Http.request({ url = 'https://cancel.example.test' }, function()
  cancelled_callback = cancelled_callback + 1
end)
local cancel_item = systems[2]
local cancel_url_path
for index, value in ipairs(cancel_item.command) do
  if value == '--config' then
    cancel_url_path = cancel_item.command[index + 1]
    break
  end
end
assert(vim.uv.fs_stat(cancel_url_path) ~= nil, '请求启动后应存在受限临时文件')
cancel()
cancel()
assert(cancel_item.killed, '取消必须终止运行中的 curl')
assert(cancelled_callback == 0, '取消后不得交付回调')
assert(vim.uv.fs_stat(cancel_url_path) == nil, '取消后必须清理临时文件')

vim.system = original_system
print('vv-utils http：通过')
