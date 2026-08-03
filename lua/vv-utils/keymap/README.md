# `vv-utils.keymap`

声明式地在 buffer-local 范围内“借用”映射，并在条件不满足时归还旧映射

## 使用

将映射规格、允许的 filetype 或自定义条件传给 `attach(opts)`；在 buffer 重用、filetype 变化或面板关闭时调用 handle 的 `refresh()` / `detach()`

`attach(opts)` 返回 handle，`refresh(buf?)` 根据 filetype 或自定义条件同步接管状态，`detach()` 解除并尝试恢复。恢复前会验证映射仍由当前 handle 持有，所以用户或后续插件的重绑永远优先，不会被旧 handle 覆盖

该模块只解决映射所有权和生命周期；何时 attach、映射动作以及条件策略由调用方声明
