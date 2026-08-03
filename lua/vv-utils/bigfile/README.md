# `vv-utils.bigfile`

## 职责

检测大文件或疑似压缩/单行文件，并在启用后关闭高开销编辑器能力

```lua
require('vv-utils').setup({ bigfile = { size = 1024 * 1024, notify = true } })
```

`is_big(buf, opts?)` 只做判断；`setup(opts?)` 安装自动处理。可配置字节阈值 `size`、平均行长阈值 `line_length`、是否 `notify`；传入 `setup(ctx)` 可覆盖默认副作用，ctx 提供 buffer 与 filetype

这不是通用性能调优器：它只在模块被启用后工作，具体禁用策略或自定义恢复策略应由调用方明确决定
