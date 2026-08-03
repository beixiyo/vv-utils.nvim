# `vv-utils.hl`

统一注册主题相关高亮，并在 `ColorScheme` 后重新应用。`register(augroup, specs, opts?)` 注册普通 spec；`register_dimmed(augroup, specs, opts?)` 从目标背景派生低对比度前景；`get_fg(name, fallback?)` 读取高亮前景

传入的 spec 不会被原地修改，适合由插件保存一份稳定基准再做调用方覆盖。高亮名称、链接策略和主题语义仍由调用方定义

## 使用

```lua
local hl = require('vv-utils.hl')
hl.register(group, { MyPanelTitle = { fg = '#cba6f7', bold = true } })
```

使用同一个 augroup 承担模块自身生命周期；不要把调用方已管理的全局 ColorScheme autocmd 隐式塞入此模块
