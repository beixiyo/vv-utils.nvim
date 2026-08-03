# `vv-utils.yaml`

面向 `pnpm-workspace.yaml` 一类简单配置的轻量解析器。`parse(text)` 解析字符串，`parse_file(filepath)` 读取后解析

## 使用

```lua
local workspace = require('vv-utils.yaml').parse_file('pnpm-workspace.yaml')
```

它不是完整 YAML 实现；复杂 tag、锚点、流式结构或需要严格 YAML 兼容性的文件应交给专用解析器。调用方应在选择它前确认目标配置只使用本模块支持的简单子集
