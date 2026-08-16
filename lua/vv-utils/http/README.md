# `vv-utils.http`

## 职责与使用

提供基于 curl 的跨平台非流式 HTTP 请求，以及严格的 URL query component 编码。URL、请求头和请求体通过权限为 `0600` 的临时文件传递，不进入进程参数

```lua
local Http = require('vv-utils.http')

local url = Http.append_query('https://example.com/search', {
  q = 'hello world',
  page = 1,
})

local cancel = Http.request({
  url = url,
  method = 'POST',
  headers = { Authorization = 'Bearer token' },
  body = vim.json.encode({ text = 'hello' }),
  timeout_ms = 15000,
}, function(error, response)
  if error then return end
  print(response.status, response.body)
end)
```

`request(opts, callback)` 返回幂等 `cancel()`。成功响应包含 `status`、`body` 和使用小写名称的 `headers`；超时、启动失败、非 2xx 状态和响应读取失败通过稳定 `error.code` 返回。该模块只负责 HTTP 机制，不解析 JSON、不决定重试或业务 fallback

`encode_query_component(value)` 仅保留 RFC 3986 unreserved 字符。`append_query(url, params)` 对参数名稳定排序，支持 URL 已有 query 和 fragment
