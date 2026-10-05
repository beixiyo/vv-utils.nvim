# `vv-utils.sys`

`open_default(path)` 通过 `vim.ui.open` 交给系统默认应用打开路径，并在 niri 环境处理打开后焦点恢复

## 使用

```lua
require('vv-utils.sys').open_default(vim.api.nvim_buf_get_name(0))
```

函数返回的是异步打开流程的结果/控制语义，调用方仍应负责错误呈现和 owner 生命周期；该模块不替插件保存窗口、决定目标应用或改写系统关联

`is_remote()` 判断当前 nvim 是否正被远程（SSH / mosh）驱动，判据与 shell 侧 `~/.local/bin/remote-session` 一致：

1. 在 tmux 内且有在连客户端：任一客户端的进程祖先链含 `sshd*` / `mosh-server*` 即远程（能识别本机起的 tmux 被 SSH / mosh attach 复用，此时 pane 环境里的 `SSH_*` 是陈旧快照，不采信）
2. 否则（不在 tmux / 没有客户端）：nvim 自身的进程祖先链
3. 再否则看环境变量：`SSH_CONNECTION`（两端都是回环地址时视为本地）/ `SSH_TTY`

`ps` 失败（不存在、非零退出、被信号终止或超时；被信号终止的命令即使退出码为 0 也按失败处理，与 shell 侧一致）视为进程链信息不可用：跳过 1、2 两步，直接按环境变量兜底。一次判定同步执行 `tmux list-clients`（仅在 tmux 内）与 `ps -A` 各最多一次（各带 500ms 超时），通常阻塞数十 ms；最坏情况下单条命令约 1s（`SystemObj:wait` 先等 500ms，超时发 SIGKILL 后再等至多 500ms），一次判定合计约 2s，SIGKILL 后仍拿不到结果按命令失败处理。结果不缓存，调用方按需自行缓存。`is_remote_async(callback)` 是不阻塞的版本，适合在 `FocusGained` 等高频事件里重新检测：单条命令超过 500ms 即发 SIGKILL 并按命令失败处理（不等进程退出，忽略 SIGTERM 的进程也不会让 callback 迟到或堆积），一次判定合计最多约 1s；判定或 callback 抛错时以 ERROR 级 `vim.notify` 报告，不会被静默吞掉

`tmux_clients({ target? })` 只给出逐客户端的分类 `{ pid, remote }[]`（机制），「任一 / 全部」由调用方决定；`target` 限定为连在该 session（可传 pane id）上的客户端。不在 tmux / 没有客户端 / 查询或 `ps` 失败返回 nil

```lua
if not require('vv-utils.sys').is_remote() then
  vim.keymap.set('n', '<Esc>', close, { buffer = buf })
end
```
