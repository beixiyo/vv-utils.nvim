# Changelog

## [Unreleased]

### Added

- **git.root / git.root_async**：探测 git 仓库根（rev-parse --show-toplevel），同步 + 异步两版
- **timer.debounce / timer.throttle 增加 `cancel` 句柄**：现返回 `(wrapped, cancel)`（向后兼容，旧 `local f = debounce(...)` 行为不变）。两者内部创建常驻 uv timer，过去无对外 close 接口 → 反复创建却不关闭会泄漏 timer 句柄。`cancel()` 幂等 `stop`+`close`，供调用方在不再使用时释放（如 vv-explorer 过滤 prompt 关闭时）

- **fs.realpath**：把路径解析到「真实路径」，用于跨来源路径比对（symlink 一致性）。`uv.fs_realpath` 解析所有中间符号链接；路径不存在时（已删除 / 父级回溯）解析「最长存在的祖先」再拼回剩余段，使已删文件与其 buffer name（解析形）仍可对齐；完全无法解析则退回 `vim.fs.normalize(fnamemodify(':p'))`。解决 `vim.fs.normalize` / `fnamemodify(':p')`（保留 symlink 形）与 `nvim_buf_get_name`（已解析真实路径）口径不一致导致的「同一文件两种路径串」漏命中

- **drop**：终端拖拽路径检测 + handler 分发（`vv-utils.drop`）。覆写 `vim.paste`，从 bracketed paste 中检测绝对路径（`/` 或 `~` 开头），支持 shell-escaped / 带引号 / `file://` URI 格式。内置默认 handler：Normal 模式 + 普通 buffer 下自动 `:edit` 打开文件。`register(handler)` 允许外部插件扩展（如 vv-explorer 拖拽粘贴到目录）。已验证终端：Kitty (Linux/macOS)、Ghostty (Linux/GTK4)、Alacritty；已知限制：Ghostty macOS (AppKit) 拖拽不走 bracketed paste，无法拦截

- **animate**：通用补间动画引擎（`vv-utils.animate`）。`add(from, to, cb, opts?)` / `del(id)` — uv_timer 驱动，支持 id 去重、int 取整、5 种内置 easing（linear / outQuad / outCubic / inQuad / inOutQuad）、duration 双模式（step_ms / total_ms）

### Changed

- **help_panel：action 名 snake_case → 空格分隔**：渲染时自动将 `cd_to` 显示为 `cd to`，不影响 actions 表查表逻辑
- **help_panel：`<C-X>` → `<C-x>` 归一化**：Neovim 对 Ctrl 键统一存大写，渲染时还原为小写（Ctrl 不区分大小写）；`<M->`/`<S->` 保持原样

### Fixed

- **timer.throttle：fn 抛错后 `running` 永久卡死、节流彻底失效**：`fn` 未 pcall 且在「启动复位 timer」之前同步调用，一旦抛错控制流逃逸 → 复位 timer 永不 `start`、`running` 永远停在 true，之后所有调用都被开头的 `if running then return` 挡掉。改为**先安排复位 timer 再调 `fn`**：fn 抛错仍向上传播（与原行为一致），但 `running` 必在 `limit` 毫秒后复位、节流自动恢复

### Added

- **fs.load_json / fs.save_json**：通用 JSON 持久化工具，支持文件路径读写和 JSON 字符串解析，文件不存在自动返回空表，父目录不存在自动创建