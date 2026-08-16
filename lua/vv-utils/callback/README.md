# `vv-utils.callback`

提供与业务和异步框架无关的回调调用控制

```lua
local Callback = require('vv-utils.callback')
local finish, disable = Callback.limit(function(result)
  print(result)
end, 1)

finish('done')
finish('ignored')
disable()
```

## API

- `limit(callback, max_calls?)`：返回受次数限制的 `invoke` 和幂等 `disable`，`max_calls` 默认为 `1`
- `invoke` 保留原回调的参数与返回值
- 调用达到上限或执行 `disable()` 后，后续调用不再执行回调
