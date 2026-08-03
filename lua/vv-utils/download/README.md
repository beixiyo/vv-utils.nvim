# `vv-utils.download`

## 职责与使用

跨平台异步下载文件，自动选择 Unix 的 curl/wget 或 Windows 的 PowerShell，并用同目录 staging 文件保证失败不会覆盖目标

```lua
local cancel = require('vv-utils.download').file({
  url = 'https://example.com/file',
  destination = '/tmp/file',
}, function(result)
  if result.ok then return end
  vim.notify(result.message, vim.log.levels.ERROR)
end)
```

`resolve(uname?)` 返回当前平台可用的下载方案。`file(opts, callback)` 要求 `url`、`destination`，`retries` 默认 3，返回幂等 `cancel()`

## 结果与边界

结果成功时为 `{ ok = true, backend = ... }`；失败时 `ok = false` 并提供 `code`（下载器缺失、下载失败或发布失败）、可展示 `message`、`backend`、`attempted`、`exitCode` 等信息。cancel 会停止活动进程、压制回调并只删自己的 staging；结果已交付后再次 cancel 是 no-op。该模块不创建父目录，也不替调用方决定重试或通知策略
