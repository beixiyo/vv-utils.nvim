# `vv-utils.history`

## 职责与使用

为多个输入字段维护彼此隔离的历史、浏览游标与草稿恢复，可选持久化到状态目录

```lua
local history = require('vv-utils.history').new({ name = 'my-plugin', persist = true })
history:record('search', 'needle')
local older = history:previous('search', current_text)
```

## API

`new(opts)` 要求安全的 `name`；`max_entries` 默认 50；`persist` 默认关闭；`path` 主要用于测试或兼容旧位置。实例的 `record(field, value)` 记录非空值并去重，`record_many(records)` 批量记录且只落盘一次；`previous(field, current)` 与 `next(field, current)` 模拟上下键，越过最新条目会恢复进入浏览前的草稿；`snapshot()` 返回不含游标和草稿的稳定记录副本

## 边界

持久化采用 0600 原子替换，并在写前合并最新磁盘记录；它不提供跨进程锁。历史实例按 `name` 隔离，不应拿它保存插件的任意结构化状态
