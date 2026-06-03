# Changelog

## [Unreleased]

### Added

- **exec**：按文件类型解析执行命令（`vv-utils.exec.resolve(path, opts?)`）。优先级 **shebang（`/usr/bin/env` 透传）> 扩展名运行器优先级**，取首个 `executable()` 的运行器，返回 `{cmd, runner}` 纯数据（无副作用，运行交给调用方）。内置 `sh/bash/zsh/fish · ts/tsx/mts/cts · js/mjs/cjs · py · lua · rb · pl · php` 默认；`opts.runners` 深合并可增减扩展名 / 改优先级，`opts.shebang=false` 关 shebang
- **git.root / git.root_async**：探测 git 仓库根（rev-parse --show-toplevel），同步 + 异步两版
- **timer.debounce / timer.throttle 增加 `cancel` 句柄**：现返回 `(wrapped, cancel)`（向后兼容，旧 `local f = debounce(...)` 行为不变）。两者内部创建常驻 uv timer，过去无对外 close 接口 → 反复创建却不关闭会泄漏 timer 句柄。`cancel()` 幂等 `stop`+`close`，供调用方在不再使用时释放（如 vv-explorer 过滤 prompt 关闭时）

- **fs.realpath**：把路径解析到「真实路径」，用于跨来源路径比对（symlink 一致性）。`uv.fs_realpath` 解析所有中间符号链接；路径不存在时（已删除 / 父级回溯）解析「最长存在的祖先」再拼回剩余段，使已删文件与其 buffer name（解析形）仍可对齐；完全无法解析则退回 `vim.fs.normalize(fnamemodify(':p'))`。解决 `vim.fs.normalize` / `fnamemodify(':p')`（保留 symlink 形）与 `nvim_buf_get_name`（已解析真实路径）口径不一致导致的「同一文件两种路径串」漏命中

- **drop**：终端拖拽路径检测 + handler 分发（`vv-utils.drop`）。覆写 `vim.paste`，从 bracketed paste 中检测绝对路径（`/` 或 `~` 开头），支持 shell-escaped / 带引号 / `file://` URI 格式。内置默认 handler：Normal 模式 + 普通 buffer 下自动 `:edit` 打开文件。`register(handler)` 允许外部插件扩展（如 vv-explorer 拖拽粘贴到目录）。已验证终端：Kitty (Linux/macOS)、Ghostty (Linux/GTK4)、Alacritty；已知限制：Ghostty macOS (AppKit) 拖拽不走 bracketed paste，无法拦截

- **animate**：通用补间动画引擎（`vv-utils.animate`）。`add(from, to, cb, opts?)` / `del(id)` — uv_timer 驱动，支持 id 去重、int 取整、5 种内置 easing（linear / outQuad / outCubic / inQuad / inOutQuad）、duration 双模式（step_ms / total_ms）

### Changed

- **sys.open_default：补错误处理 + 返回值**：`vim.ui.open` 失败（无可用 opener，如纯 headless / 无 GUI 的 SSH）时 `vim.notify` 报错而非静默吞错，并返回 `boolean ok`（向后兼容，旧调用忽略返回值即可）。文档明确语义：目录→系统文件管理器、文件→默认程序
- **sys.open_default：niri 焦点跟随**：niri 默认丢弃应用的 xdg-activation 聚焦请求（如已开 Firefox 里开新标签不抢焦点）。`$NIRI_SOCKET` 存在时，打开后异步经 `xdg-mime` 解析默认处理程序、轮询 `niri msg --json windows` 按 app_id（标题含文件名优先）定位并 `focus-window` 聚焦回来；非 niri 环境完全无副作用
- **help_panel：action 名 snake_case → 空格分隔**：渲染时自动将 `cd_to` 显示为 `cd to`，不影响 actions 表查表逻辑
- **help_panel：`<C-X>` → `<C-x>` 归一化**：Neovim 对 Ctrl 键统一存大写，渲染时还原为小写（Ctrl 不区分大小写）；`<M->`/`<S->` 保持原样

### Fixed

- **format.apply_to_buffer：nvim_buf_set_lines 前判 modifiable，nomodifiable/只读 buffer 上不再抛 E21，改友好 WARN 返回**
- **drop.try_resolve_path：先按原始路径 fs_stat、未命中再 shell_unescape 后备，不再误删 Kitty 等原始路径里的字面反斜杠**
- **animate：缓动循环从 i=0 起（d=step_count-1），首帧等于 from，消除动画起步突变**
- **fs.exists：改用 fs_lstat（不跟随软链），broken symlink 不再被判为不存在，rename/create/unique_dest 的冲突检查不再被越过而静默覆盖软链**
- **fs.read_all：循环补读到读满/EOF，修复 fs_read 短读（>2GB / 网络 FS / 信号中断）时静默返回截断内容**
- **fs.sync_buffers：`nvim_buf_set_name` 包 pcall，目标名已被其它 loaded buffer 占用（E95）时不再冒泡中断调用方的后续 UI 刷新**
- **fs.copy：dst 位于 src 子树内时硬报错，杜绝复制目录进自身导致的无限递归（写满磁盘）**
- **timer.throttle：fn 抛错后 `running` 永久卡死、节流彻底失效**：`fn` 未 pcall 且在「启动复位 timer」之前同步调用，一旦抛错控制流逃逸 → 复位 timer 永不 `start`、`running` 永远停在 true，之后所有调用都被开头的 `if running then return` 挡掉。改为**先安排复位 timer 再调 `fn`**：fn 抛错仍向上传播（与原行为一致），但 `running` 必在 `limit` 毫秒后复位、节流自动恢复

### Added

- **fs.load_json / fs.save_json**：通用 JSON 持久化工具，支持文件路径读写和 JSON 字符串解析，文件不存在自动返回空表，父目录不存在自动创建