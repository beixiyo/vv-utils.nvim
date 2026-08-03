# `vv-utils.drop`

## 职责

把终端路径拖放统一为 `handler(paths, pos)`：bracketed paste 提供无坐标路径，Kitty OSC 72 可额外提供落点与拖动事件

## 启用与使用

```lua
require('vv-utils').setup({ drop = { kitty_dnd = true } })

local drop = require('vv-utils.drop')
drop.register(function(paths, pos)
  if not pos then return false end
  -- 根据 pos.x / pos.y 决定落点
  return true
end)
```

`setup(opts?)` 安装 `vim.paste` 拦截并尝试启用 Kitty 协议；`teardown()` 只在仍由本模块持有时恢复原 `vim.paste`。`detect_paths(lines)` 可独立检测粘贴文本，`register(handler)` 注册处理器，`on_drag(cb)` 订阅 `move` / `leave`

## 协议边界

`pos = nil` 表示普通粘贴路径；非 nil 时包含 cell 坐标和允许操作。Kitty DnD 需要 Kitty 0.47+ 且 Neovim 直接运行在 Kitty 中；tmux 不透传入站 OSC，会自动退回粘贴路径检测。handler 返回 `true` 才表示已消费
