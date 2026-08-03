# `vv-utils.path_completion`

## 职责

为输入框提供不依赖 UI 的路径候选，统一处理 glob 的逗号分段、相对路径前缀和候选预算。既可扫描文件系统，也可复用调用方已有的相对路径索引

## 使用

```lua
local paths = require('vv-utils.path_completion')
local result = paths.glob('src/**/*.lua, !tests', { cwd = vim.fn.getcwd() })
-- result.start_col 为 0-based 替换起点，result.items 为候选
```

## API

| 函数 | 说明 |
|---|---|
| `glob(input, opts?)` | 同步生成 glob 输入的文件与目录候选 |
| `glob_async(input, opts?, callback)` | 异步生成候选，返回幂等 cancel |
| `glob_from_paths(input, paths, opts?)` | 只用传入的相对路径索引生成候选，不访问文件系统 |
| `directory(input, opts?)` | 同步生成纯目录候选 |
| `directory_async(input, opts?, callback)` | 异步目录候选，返回幂等 cancel |

所有查询支持 `cwd`、0-based `cursor`、最终上限 `max_items`、扫描上限 `scan_max_items` 和超时 `timeout_ms`；默认分别为当前 cwd、输入末尾、50、1000、250ms

## 边界

`../` 与绝对 glob 不会越过候选根。同步接口适用于已有索引或小范围调用；面向交互输入时应选异步接口，并在输入变更或关闭时调用返回的 cancel
