# `vv-utils.state`

## 职责

为多个插件提供两级命名空间的 JSON 持久状态，避免不同插件直接共享一个无边界的状态表

```lua
local state = require('vv-utils.state').register('my-plugin', 'references')
state:set('width', 52)
local width = state:get('width', 52)
```

## API

`register(plugin_id, key_id, opts?)` 返回 handle；ID 只能包含字母、数字、点、下划线和连字符。`opts.path` 可隔离存储位置，默认是 `stdpath('state')/vv-utils/state.json`，可用 `default_path()` 查询

handle 提供 `get(field, default?)`、`set(field, value)`、`remove(field)`。读操作与默认值都会深拷贝，写入值必须可 JSON 编码；要删除字段必须用 `remove()`，不能传 `nil`

## 边界

每次写入会重读并合并磁盘快照，再以 0600 原子替换，但没有跨进程锁。它适合小型插件偏好与 UI 状态，不适合作为高频缓存或并发数据库
