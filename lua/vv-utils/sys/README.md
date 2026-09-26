# `vv-utils.sys`

`open_default(path)` 通过 `vim.ui.open` 交给系统默认应用打开路径，并在 niri 环境处理打开后焦点恢复

## 使用

```lua
require('vv-utils.sys').open_default(vim.api.nvim_buf_get_name(0))
```

函数返回的是异步打开流程的结果/控制语义，调用方仍应负责错误呈现和 owner 生命周期；该模块不替插件保存窗口、决定目标应用或改写系统关联

`is_remote()` 判断当前 nvim 是否正被 SSH 远程驱动：在 tmux 内看在连客户端的进程祖先链是否含 `sshd`（能识别本机起的 tmux 被 SSH attach 复用，此时环境里没有 `SSH_CONNECTION`），否则回退到 `SSH_CONNECTION` / `SSH_TTY`。它同步执行 `tmux list-clients` 与 `ps -A`，结果不缓存，调用方按需自行缓存。`is_remote_async(callback)` 是不阻塞的版本，适合在 `FocusGained` 等高频事件里重新检测

```lua
if not require('vv-utils.sys').is_remote() then
  vim.keymap.set('n', '<Esc>', close, { buffer = buf })
end
```
