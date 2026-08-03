# `vv-utils.completion`

## 职责

为调用方持有的 buffer 注册补全 descriptor。该模块不依赖 Blink 或任何特定补全框架；adapter 只需读取当前 buffer descriptor

## 使用

```lua
local completion = require('vv-utils.completion')
local detach = completion.attach(buf, completion.path({ mode = 'glob', cwd = cwd }))
-- buffer 关闭或面板销毁时调用 detach()
```

## API

`attach(buf, descriptor)` 安装 descriptor 并返回幂等 `detach()`；后安装者不会被早期 handle 的 `detach()` 误删。`get(buf)` 获取当前 descriptor，`detach(buf)` 直接移除。buffer detach 时内部引用也会清理

descriptor 的 `complete(context, defaults, callback?)` 可同步返回 `{ start_col, items, pre_filtered? }`，或异步调用 callback 并返回幂等取消函数。`enabled?()` 用于按输入状态禁用补全，`trigger_characters?` 声明触发字符

`path(opts)` 生成路径 descriptor：`mode` 必须为 `'glob'` 或 `'directory'`；`cwd` 可为字符串或延迟函数；`max_items`、`scan_max_items`、`timeout_ms` 可覆盖 adapter 默认预算

## 边界

descriptor 的候选、排序和业务可见性都由调用方定义。`pre_filtered = true` 表示 adapter 不得再次重排；异步 descriptor 必须自行提供可取消的真实查询
