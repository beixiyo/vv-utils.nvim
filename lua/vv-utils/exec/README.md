# `vv-utils.exec`

## 职责

仅解析“一个文件应该如何执行”，不启动进程。它让上层 UI、终端或任务系统共享 shebang 与扩展名 runner 的选择规则

```lua
local resolved = require('vv-utils.exec').resolve('/work/script.ts')
if resolved then vim.system(resolved.cmd) end
```

`resolve(path, opts?)` 返回 `{ cmd, runner }` 或 `nil`。默认先读取 shebang（包括 `/usr/bin/env` 透传），未命中再从扩展名对应 runner 优先级中选第一个 `executable()` 的命令。`opts.shebang = false` 关闭 shebang，`opts.runners` 覆盖映射

## 边界

返回值是纯 argv 数据，不包含 shell 拼接、cwd、环境变量、终端展示或错误通知；这些属于调用方执行策略
