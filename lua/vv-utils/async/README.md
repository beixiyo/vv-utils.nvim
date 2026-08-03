# `vv-utils.async`

为异步工作的 owner 提供 request 生命周期管理

它解决的不是“如何启动进程”，而是下面这些时序问题：

- 新查询已经开始，旧查询的回调才到达
- 面板关闭后，timer、LSP 或 `vim.schedule()` 回调仍会执行
- 一个清理回调同步触发下一个 request
- owner 需要停止所有仍在运行的 producer

模块明确区分三件事：

| 概念     | 含义                                                     |
| -------- | -------------------------------------------------------- |
| 逻辑失效 | 结果不再允许写回 UI 或状态                               |
| 物理取消 | 调用方真正停止 process、timer、LSP request 等资源        |
| 资源释放 | 调用方关闭 listener、window、buffer、timer handle 等资源 |

`vv-utils.async` 不猜测资源类型。谁创建资源，谁通过 `cancel` / `dispose` 回调告诉 request 如何处理它

## 最小用法

```lua
local scope = require('vv-utils.async').scope({
  cancel_previous = true,
})

local request = scope:begin({
  key = 'refresh',
  mode = 'latest',
})

local process = vim.system({ 'rg', '--files' }, { text = true }, function(result)
  vim.schedule(function()
    if request:finish() then
      publish(result.stdout)
    end
  end)
end)

request:set_cancel(function()
  process:kill('sigterm')
end)
```

`finish()` 返回 `true` 才代表这一次结果仍可发布。不要只看回调是否到达

## 先记住四个对象

```text
调用方
  │
  ├─ Scope                  一个 owner，例如面板、会话或控制器
  │    │
  │    ├─ active            仍可能需要被 owner 清理的 request
  │    ├─ controls          Scope 私下驱动 request 的 capability
  │    └─ lanes             按 key 管理 latest / parallel 规则
  │
  └─ request                一次具体异步工作的公开票据
       │
       └─ private state     身份、生命周期、清理回调与 lane 信息
```

调用方只需要持有 `scope` 与 `request`。`control`、`host` 和内部 state 都不是公共 API

## Scope 保存什么

Scope 是 owner 的总账。它在 [scope.lua](scope.lua) 中持有三张运行时表：

| 数据        | 键和值              | 用途                                              | 删除时机            |
| ----------- | ------------------- | ------------------------------------------------- | ------------------- |
| `_active`   | `id → request`      | 找到仍可能需要 owner cancel 的 request            | request 终态时      |
| `_controls` | `request → control` | Scope 私下执行带 reason 的 invalidate / terminate | 与 active 同时删除  |
| `_lanes`    | `key → lane`        | 保存并发模式、版本与引用计数                      | `references` 归零时 |

一个 lane 包含：

```text
mode        latest 或 parallel
revision    latest 模式的版本号
references  该 key 尚未终态的 request 数量
latest      当前允许发布的 request，仅 latest 模式使用
```

`_active` 和 `_controls` 保留逻辑失效的 request。这样先 `invalidate()` 后，owner 仍能在稍后 `cancel()` 真正停止旧 producer

## request 实际保存什么

公开的 request 表不保存 `_state`、`_host` 等字段。它只通过受保护 metatable 暴露公共方法

每个 request 的私有 state 保存在该实例方法的闭包中：

```text
身份
  id / epoch / key / revision / mode / lane

生命周期
  active / invalidated / finished / cancelled / disposed
  reason

清理 slot
  cancel   = { callback, requested, called }
  disposer = { callback, requested, called }

协作能力
  host.snapshot()
  host.detach()
  host.release_lane()
```

这种存储方式有两个目的：

1. 调用方无法依赖内部字段或内部协作方法
2. terminal request 不会被模块级 state map 长期保留；如果 disposer 闭包捕获 request，它们仍是可整体回收的普通闭包环

相关 GC 行为由 [异步回归测试](../../../tests/test_async_scope.lua) 覆盖

## `begin()` 的数据流

`scope:begin(opts?)` 创建 request 的顺序如下：

```text
1. 归一化 key、mode 与 cancel_previous
2. 查找或创建 lane[key]
3. lane.references += 1
4. latest 模式下 lane.revision += 1
5. 创建 request 与只供 Scope 持有的 control
6. 写入 active[id] 与 controls[request]
7. latest 模式下处理旧 latest request
8. 绑定 opts.cancel / opts.dispose
```

若存在同 key 的旧 request：

| 配置                      | 旧 request 的处理                                           |
| ------------------------- | ----------------------------------------------------------- |
| `cancel_previous = false` | 仅逻辑失效，旧 producer 继续运行直到自行结束或 owner cancel |
| `cancel_previous = true`  | 立即物理 cancel 并 dispose                                  |

同一个仍有在途 request 的 key 不能混用 `latest` 与 `parallel`。等 lane 完全释放后，才允许换模式重新使用该 key

## `is_current()` 在检查什么

request 只有同时满足以下条件，才可以发布异步结果：

```text
request 自己仍是 active
Scope 尚未 dispose
request 的 epoch 等于 Scope 当前 epoch
Scope.active[id] 仍指向这个 request
Scope.lanes[key] 仍是这个 request 所属 lane
latest 模式下，lane.latest 仍是这个 request
```

这比“比较一个递增 ID”更严格。它同时验证 owner、request 登记、lane 和版本归属

## 三种终态操作

| 方法        | 物理 cancel | disposer | 适用场景                                  |
| ----------- | ----------: | -------: | ----------------------------------------- |
| `finish()`  |          否 |       是 | producer 已正常完成                       |
| `cancel()`  |          是 |       是 | 必须停止仍在运行的 producer               |
| `dispose()` |          否 |       是 | producer 已由其他路径停止，只释放关联资源 |

三者都使用同一条终态流水线：

```text
1. 记录终止前是否仍 current
2. 写入终态与 reason
3. 从 Scope.active / controls / latest 指针解绑
4. 必要时执行 cancel callback
5. 执行 disposer callback
6. 再检查一次是否仍获授权发布
7. lane.references -= 1；归零时删除 lane
```

第 3 步必须早于 callback。因为 callback 可以同步 `begin()`、`finish()` 或 `scope:cancel()`；旧 request 不能在重入时重新影响 Scope 的登记

第 6 步用于处理同步后继请求。例如 A 的 disposer 创建并完成 B 时，A 虽然在开始结束前是 current，最终也必须返回 `false`

## 为什么 cleanup slot 有三个字段

每个 `cancel` / `disposer` 都是：

```lua
{
  callback = nil,
  requested = false,
  called = false,
}
```

| 字段        | 回答的问题                     |
| ----------- | ------------------------------ |
| `callback`  | 调用方是否已经交付真实清理函数 |
| `requested` | 生命周期是否已经要求执行它     |
| `called`    | 是否已经真正调用过             |

这解决“producer 同步完成、handle 稍后才返回”的场景：

```lua
local request = scope:begin()

local cancel, disposer = start(function()
  request:finish()
end)

request:set_cancel(cancel)
request:set_disposer(disposer)
```

`finish()` 已把 disposer 标记为 requested。后续 `set_disposer()` 会立即执行它一次；`called` 保证重复终态或同步重入也不会重复清理

## owner 级操作

| Scope 方法     | request 状态            | 是否物理取消 | Scope 是否可复用 |
| -------------- | ----------------------- | -----------: | ---------------: |
| `invalidate()` | 逻辑失效，仍留在 active |           否 |               是 |
| `cancel()`     | 终态并释放              |           是 |               是 |
| `dispose()`    | 终态并释放              |           是 |               否 |

`invalidate()` 不会把 request 从 `_active` 删除。这不是泄漏；它确保后续 `scope:cancel()` 仍能找到并停止实际 producer

## 为什么 owner teardown 先做快照

`scope:cancel()` 与 `scope:dispose()` 会先捕获：

```text
{ request = A, control = controlA }
{ request = B, control = controlB }
{ request = C, control = controlC }
```

然后才逐项终止

A 的 cancel callback 可能同步 finish B，并删除 `controls[B]`。外层 teardown 不能在遍历到 B 时再从可变 map 查 control；它必须使用快照中已经捕获的 `controlB`。第二次终止 B 只是幂等 no-op，C 仍会继续清理

测试刻意不假设 `pairs()` 顺序，覆盖任意一项先触发、同步 finish 下一项的情况

## 公共 API

```lua
local Async = require('vv-utils.async')

local scope = Async.scope({
  cancel_previous = false,
})

local request = scope:begin({
  key = 'default',
  mode = 'latest',
  cancel_previous = false,
  cancel = function() end,
  dispose = function() end,
})
```

| 对象    | 方法               | 说明                                             |
| ------- | ------------------ | ------------------------------------------------ |
| scope   | `begin(opts?)`     | 创建 request                                     |
| scope   | `invalidate()`     | 只让全部在途 request 逻辑失效                    |
| scope   | `cancel()`         | 取消并释放全部在途 request，但 Scope 可复用      |
| scope   | `dispose()`        | 取消并释放全部在途 request，永久关闭 Scope       |
| scope   | `is_disposed()`    | 查询 Scope 是否永久关闭                          |
| request | `is_current()`     | 查询当前回调能否发布结果                         |
| request | `invalidate()`     | 只让该 request 逻辑失效                          |
| request | `set_cancel(fn)`   | 绑定物理取消函数；若已请求 cancel 则立即执行一次 |
| request | `set_disposer(fn)` | 绑定释放函数；若已请求释放则立即执行一次         |
| request | `finish()`         | 正常结束，返回是否仍允许发布                     |
| request | `cancel()`         | 物理取消并释放，返回是否曾是 current             |
| request | `dispose()`        | 只释放，返回是否曾是 current                     |
| request | `reason()`         | 返回失效或终态原因                               |

## 使用边界

`vim.schedule()`、已发送的 LSP 请求和已触发的回调不能仅靠逻辑失效从运行时队列中撤回。因此：

1. 在结果回调中调用 `request:finish()` 或 `request:is_current()`
2. 为真正可取消的资源提供 `set_cancel()`
3. 为 timer、listener、buffer、window 等资源提供 `set_disposer()`

如果没有资源需要释放，不必为了形式传空 callback
