# `vv-utils.editor`

## 职责

封装剪贴板写入、Visual 范围读取和可复制路径构建，保证面板与普通 buffer 使用一致的路径与行号语义

```lua
local editor = require('vv-utils.editor')
editor.copy_path({ relative = true, line = true, notify = false })
```

## API

`copy(text, opts?)` 写入剪贴板。`visual_range()` 返回当前 Visual 选区。`build_path(opts?)` 只构建文本，`copy_path(opts?)` 构建后复制；两者接受显式 `path`、相对 `path.get_root()` 的 `relative`、自动/显式范围的 `line`。`copy_path` 额外支持 `notify` 和通知标题 `title`

## 边界

没有文件路径时构建会返回 nil；模块不会保存 buffer、切换 cwd 或替调用方判断路径是否适合暴露给用户
