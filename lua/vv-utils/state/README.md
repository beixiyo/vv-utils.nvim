# `vv-utils.state`

## 职责

为多个插件提供两级命名空间的 JSON 持久状态，避免不同插件直接共享一个无边界的状态表

```lua
local state = require('vv-utils.state').register('my-plugin', 'references')
state:set('width', 52)
local width = state:get('width', 52)
```

## API

`register(plugin_id, key_id, opts?)` 返回 handle；ID 只能包含字母、数字、点、下划线和连字符。`opts.path` 可隔离存储位置，默认是 `stdpath('state')/vv-utils/state.json`，可用 `default_path()` 查询。路径会在 API 边界解析到真实路径，使用同一文件的 symlink 别名也会共享状态、锁和订阅。锁选项 `lock_timeout_ms`、`lock_stale_ms`、`lock_retry_ms` 分别默认为 5000、30000、10 毫秒

handle 提供 `get(field, default?)`、`set(field, value)`、`remove(field)`、`compare_and_set(field, expected, value)` 和 `subscribe(field, callback, opts?)`。读操作与默认值都会深拷贝，写入值必须可 JSON 编码；`set` 不能传 `nil`，要删除字段使用 `remove()`。CAS 的 `value = nil` 表示删除：

```lua
local updated, current, error_message = state:compare_and_set('width', 52, 60)
if not updated and error_message then
  vim.notify(error_message, vim.log.levels.ERROR)
elseif not updated then
  -- current 是锁内读到的新值，调用方可以决定是否重试
end
```

`compare_and_set` 返回 `updated, current, error_message`。成功时 `updated = true` 且 `current` 是写入值；比较不匹配时 `updated = false`、`current` 是锁内观察到的值；读、写或锁失败时第三个返回值是错误信息

`subscribe` 监听同一个状态文件的原子替换，并只在目标字段的值真正变化时调用 `callback(value, previous)`。同一 Neovim 进程内，相同路径共享一个目录级 `fs_event`；每个订阅独立防抖，`opts.debounce_ms` 默认 20 毫秒。返回的 `unsubscribe` 幂等，必须由创建订阅的生命周期所有者释放：

```lua
local unsubscribe = state:subscribe('width', function(width, previous)
  print(('width: %s -> %s'):format(previous, width))
end)

unsubscribe()
```

## 边界

`set`、`remove` 和 `compare_and_set` 使用固定 sibling 锁 `<state-path>.lock`，以 `O_EXCL` 创建并将锁覆盖整个同步的“读 → 比较/修改 → 保存”区段；保存仍由 `vv-utils.fs.save_json` 以 0600 和同目录临时文件原子替换。`get` 是一个无锁的原子文件快照读取

锁文件记录 owner pid。进程崩溃留下的锁只有在超过 `lock_stale_ms` 且 owner 不再存活（平台支持 pid 探测时）或 owner 信息不可用时才会回收；仍在运行的 owner 不会因为 callback 慢而被抢占。等待超过 `lock_timeout_ms` 会返回错误，不会无限阻塞。锁内 callback 是实现内部的同步 callback，不能 yield 或重新进入状态写入；状态 API 不提供持锁异步 callback

订阅依赖操作系统文件事件，不通过 socket 或进程内共享内存；因此不同 Neovim 实例各自持有 watcher，并通过同一个磁盘文件交换状态。它适合小型插件偏好与 UI 状态，不适合作为高频缓存、消息队列或并发数据库
