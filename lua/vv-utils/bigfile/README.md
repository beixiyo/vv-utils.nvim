# `vv-utils.bigfile`

## 职责

检测大文件或疑似压缩/单行文件，并在启用后关闭高开销编辑器能力

```lua
require('vv-utils').setup({ bigfile = { size = 1024 * 1024, notify = true } })
```

`is_big(buf, opts?)` 只做判断；`setup(opts?)` 安装自动处理。可配置字节阈值 `size`、平均行长阈值 `line_length`、是否 `notify`

默认处理会在下个 tick 关闭命中 bigfile 的 buffer 的传统 Vim syntax（`syntax = false`），普通文件及原生 Git diff 红绿高亮不受影响。传统 syntax 不等于 Treesitter：在超大文件中跳到深处（例如 Git diff 的首个改动）时，它也可能阻塞重绘。如需恢复原语言的传统高亮，可显式启用：

```lua
require('vv-utils').setup({ bigfile = { syntax = true } })
```

这不是通用性能调优器：它只在模块被启用后工作，具体禁用策略或自定义恢复策略应由调用方明确决定
