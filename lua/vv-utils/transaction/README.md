# `vv-utils.transaction`

`vv-utils.transaction` 是与具体副作用无关的事务机制。它负责按顺序执行预检、
维护 busy 状态、失败后的逆序补偿、补偿不完整时锁定实例，以及最近一次成功事务的
一层撤回。每个 operation 自己负责策略；模块不会猜测 operation 的业务语义

## API

```lua
local Transaction = require('vv-utils.transaction')

local transaction = Transaction.new({
  operations = {
    {
      name = 'write config',
      validate = function(context)
        return context.config_is_fresh
      end,
      apply = function(context)
        context.config = 'new'
      end,
      compensate = function(context)
        context.config = 'old'
      end,
    },
  },
})

local ok, error = transaction:apply()
if ok then transaction:undo() end
```

`new(opts)` 使用 options 对象。也可以把 `operations` 传给
`run(operations, context?, callback?)` 或 `apply(...)`。只有当每个 operation
都提供 `compensate` 或 `rollback` 时，成功事务才可撤回。`undo()` 消费这一层记录；
下一次成功的 `apply()` 会替换它

## 同步与 callback operation

operation 可以同步返回，失败时返回 `false, error`；也可以通过第二个参数 callback
异步完成：

```lua
local pending = Transaction.new({ operations = {
  {
    async = true,
    validate = function(_, done)
      vim.defer_fn(function() done(true) end, 10)
    end,
    apply = function(_, done)
      vim.defer_fn(function() done(true) end, 10)
    end,
    compensate = function(_, done)
      vim.defer_fn(function() done(true) end, 10)
    end,
  },
} })

pending:apply(function(ok, error)
  -- 全部阶段完成后只回调一次
end)
```

### 回调约定

callback 签名为 `(ok, value_or_error)`：

| 调用 | 结果 |
| --- | --- |
| `done(true, value)` | 成功，并记录 `value` |
| `done(false, error)` | 失败 |
| `done()` | 成功，无返回值 |

通过 callback 完成的 operation 必须设置 `async = true` 或 `callback = true`

- callback 到达前忽略函数返回值，包括 function、table、cdata 和 `vim.system` handle
- 未标记的 operation 按同步返回值完成，之后到达的 callback 无效
- callback 被多次调用时，只接受第一次结果

### 执行与补偿顺序

1. 按声明顺序执行全部 `validate`
2. 预检全部通过后，按声明顺序执行 `apply`
3. `apply` 失败后，逆序补偿所有已进入 apply 的 operation
4. 最近一次成功且可补偿的事务可通过 `undo()` 逆序撤回

报告失败的当前 operation 默认也参与补偿。任一补偿失败都会锁定实例；恢复外部副作用后，
应创建新的事务实例。异步预检、apply、补偿和 undo 期间，实例始终保持 busy

### 标记无副作用失败

如果 operation 能确认失败发生在任何副作用之前，返回：

```lua
return false, Transaction.failure(error, false)
```

该 operation 不会进入失败补偿或 undo 恢复。未显式标记的失败按“可能已经产生副作用”处理

### 状态

| 方法 | 含义 |
| --- | --- |
| `can_undo()` | 最近一次成功事务是否可撤回 |
| `is_busy()` | 是否正在预检、应用、补偿或撤回 |
| `is_locked()` | 是否因补偿不完整而锁定 |

`apply()` 和 `undo()` 明确会产生副作用；`validate` 只负责 operation 自己的只读预检
