# Changelog

## 0.5.6 - 2026-08-10

### Added

- **confirm**：新增通用确认浮窗，支持消息与详情、危险级别、可配置确认/取消按键、语义高亮
- **transaction**：新增与业务无关的事务机制
- **keys**：新增统一键位展示与提示格式化，支持修饰键、复合键和特殊键

### Changed

- **exec**：新增 rust、go、zig 等解析
- **help_panel / input**：统一使用 `keys` 生成键位展示文本

## 0.5.5 - 2026-08-08

### Fixed

- **scroll 粘贴保护**：终端括号粘贴期间不再损坏内容。自动动画每帧由 `normal! N<C-e>` 驱动，而 `normal!` 会重入 Neovim 的输入处理

### Added

- **scroll**：新增 `pasting()`，查询当前是否处于终端粘贴保护期

## 0.5.4 - 2026-08-07

### Added

- **fs**：新增目录统计 `inspect_dir` / `scan_dir` / `dir_info_lines`。递归扫描用显式 DFS 栈保存 scandir 句柄，按 entry 粒度检查预算后经 uv timer 让出事件循环，单片占用可控（89 万文件目录下主线程单次最长占用 18ms）；支持 `max_entries` 截断、`max_depth` 限深与随时 `cancel`，不跟随 symlink 因而不会成环
- **fs**：`file_info_highlight` 增加 `pending` / `truncated` 分组与共享状态标记，让扫描中和被截断的数值不会被读成最终结果

## 0.5.3 - 2026-08-03

### Added

- **async**：新增 `Scope` 请求生命周期管理。支持按 key 的 `latest` / `parallel` 并发模式、过期结果授权校验、owner 级 invalidate / cancel / dispose，以及 cancel 与 disposer 的一次性资源释放

### Changed

- **文档**：模块用法与 API 说明移动到各模块目录的 `README.md`

## 0.5.2 - 2026-08-01

### Added

- **git**：新增 `highlight_specs()`，返回共享 `VVGit*` 高亮静态基准的隔离副本，供调用方安全叠加配置并在重复 setup 时恢复默认值

## 0.5.1 - 2026-07-30

### Added

- **fs 文件探测**：新增 `inspect_file()` / `is_binary()`。新增 `file_info_lines()` 与 `highlight_file_info()`

### Changed

- **format.project**：二进制判断复用 `vv-utils.fs`
- **exec 错误信息**：未知文件类型与缺少可用 runner 的用户提示统一改为英文

## 0.5.0 - 2026-07-29

### Added

- **completion / blink**：新增 buffer-local 补全 descriptor 与可选 `vv-utils.blink` source
- **glob / path_completion**：新增框架无关的 `compile()` / `compile_list()` 结果

### Changed

- **path_completion**：最终候选默认上限从 200 收紧为 50；递归 `fd` 原始结果预算改为独立 `scan_max_items`（默认 1000），不再由 `max_items * 20` 隐式放大
- **path_completion / blink**：descriptor 补全链支持异步 callback 与取消；当前目录分批扫描，递归 `fd` 不再同步等待或逐项 `fs_stat`
- **glob**：`compile_rg()` / `compile_rg_list()` 改为通用编译结果之上的 ripgrep adapter

### Fixed

- **prompt 输入边界**：用双行结构守卫统一处理 `dd`、`dG` 等跨行删除；空输入继续按 Backspace 也不会越过输入行
- **prompt label 间距**：icon 为空时不再保留无意义的图标后空格

## 0.4.3 - 2026-07-29

### Added

- **hl**：改为 `hl/init.lua` 文件夹模块并保持原公共入口兼容；新增 `register_dimmed(augroup, specs, opts?)`，从现有高亮派生向指定背景降低对比度的颜色，并在 `ColorScheme` 后重新计算
- **color**：新增提供 `parse()`、`to_hex()`、`to_integer()`、`mix()` 与 `composite()`；统一支持 Neovim integer RGB、`#RGB[A]`、`#RRGGBB[AA]` 和 RGBA 对象

## 0.4.2 - 2026-07-28

### Fixed

- **fs.rename**：在大小写不敏感文件系统上，纯大小写改名（如 `README.MD` → `README.md`）不再被误判为目标已存在。仅当两条路径大小写等价且 `dev` / `ino` 确认指向同一个文件对象时放行；不同文件仍拒绝覆盖

## 0.4.1 - 2026-07-27

### Added

- **keymap**：新增 buffer-local 映射生命周期管理。`attach(opts)` 按 `filetypes`、`enabled` 与自定义 `when` 条件接管映射；FileType 切换、`refresh()` 或 `detach()` 时只恢复仍由自身持有的映射，保留用户中途重绑的快捷键，并在 `BufWipeout` 自动清理内部状态

## 0.4.0 - 2026-07-27

### Changed

- **lsp.code_actions**：同一阶段向全部 LSP 客户端并行请求 Code Action，并让 `textDocument/codeAction` 与 `codeAction/resolve` 共享单次绝对截止时间；多客户端不再按数量累计等待，超时后取消仍在进行的请求
- **lsp.fix**：新增 `check_path_support(path, configs?)`，在创建临时 buffer 前检查 filetype、已启用配置与 LSP 可执行文件，缺少配置或可执行文件时立即返回结构化错误，避免无可用 LSP 时空转等待
- **tree_panel**：将分散在实现模块中的公开类型集中到 `tree_panel/types/init.lua`，由模块入口统一加载；仅整理类型所有权，不改变运行时行为

### Breaking

- **lsp.fix**：删除 `supports_path(path, configs?)`，调用方需改用返回 `(supported, error?)` 的 `check_path_support(path, configs?)`

## 0.3.3 - 2026-07-26

### Changed

- **path**：新增 `find_root(path, opts?)`；项目根解析优先上层 `.git` 工作树标记，未命中时再回退到最近的跨语言包管理或构建 manifest，`get_root()` 复用该逻辑

## 0.3.2 - 2026-07-26

### Added

- **state**：新增按插件 ID 与功能 key 隔离的 JSON 状态仓库；写入前合并最新磁盘快照，以 `0600` 权限原子保存，并拒绝静默覆盖损坏的状态文件
- **tree_panel**：新增调用方驱动的通用树形侧栏，支持左右布局、稳定折叠、自定义渲染与快捷键、固定 winbar、Tree-sitter 片段高亮、预览跳转和持久宽度
- **input**：新增无状态输入行装饰器，统一渲染 label、placeholder 与快捷键提示，并由调用方持有输入值和生命周期

### Changed

- **prompt**：复用 `vv-utils.input` 渲染标签与 placeholder，保留既有浮窗和过滤生命周期
- **fs**：JSON 读写支持严格解码与显式文件权限，供状态仓库安全持久化
- **drop**：注册处理器和拖拽监听时返回幂等 disposer，并提供 teardown 释放 Kitty 监听、按 ownership 还原 `vim.paste`
- **scroll**：新增 disable 生命周期，取消运行中的动画，并仅还原仍由模块持有的映射和 `mousescroll`

## 0.3.1 - 2026-07-19

### Changed

- 将大型工具按领域拆分为目录模块，并通过各领域的 `init.lua` 统一公开 API
- 文件事务并入 `vv-utils.fs.new_transaction()`，删除独立的 `vv-utils.fs_transaction` 入口

## 0.2.1 - 2026-07-19

### Added

- **path_completion**：新增不绑定 UI 的路径候选引擎。按光标识别顶层逗号分段，保留 `!` / `./` 和含空格路径，转义文件名中的 glob 特殊字符；分别支持 Include / Exclude 的文件与目录候选，以及 Cwd 的纯目录候选。未以 `./` 锚定的片段可通过 `fd` 按需补全任意深度路径，不创建常驻索引

## 0.2.0 - 2026-07-19

### Added

- **glob**：新增 VS Code 风格搜索 glob 编译。支持顶层逗号拆分、brace / 字符类 / 转义逗号、`./` 搜索根锚定、`!` 排除，并同时生成路径本体与目录后代 pattern，避免通过扩展名猜测文件/目录
- **fs_transaction**：新增可实例化的文件内容事务。每个实例独立保存最近一次成功快照，统一负责全量预检、逐文件原子写入、写后校验、失败补偿回滚与单层撤回；默认拒绝覆盖未保存的 Neovim buffer

## 0.1.0 - 2026-07-13

### Added

- **lsp.fix**：新增可复用的 LSP 自动修复引擎。统一负责 filetype 识别、客户端冷启动等待、Code Action 双采样收敛、单文件原子应用和临时 buffer 清理；`files()` 以异步串行方式处理多文件

- **mouse**：新增 `block_visual_drag(buf)`，给 nofile 面板挂 ModeChanged 守卫，禁止鼠标拖拽 / 多击进 visual。补 buffer-local Nop 的盲区——跨窗口「从别窗点进面板再拖 / 多击」时按下走源窗口 keymap，buffer-local 拦不住，守卫一旦进 visual 即退回 normal。caller：vv-explorer / vv-git（实现细节见模块注释）

- **bigfile.is_big**：把大文件判定从 `setup()` 的 `.*` filetype detector 中抽成公开谓词 `is_big(buf, opts?)`（字节数超 `size` 或平均行长超 `line_length`，已标 `bigfile` 直接认定），detector 改为复用它（单一真源）。供其它模块在真正动手前自我设限——首个 caller 是 vv-log-hl（超大日志跳过逐行 badge 扫描）

- **loading**：通用 buffer 行内 loading 动画（`vv-utils.loading`）。`start(opts)` 在指定 buffer 行末尾以 virt_text 渲染滚动帧动画，返回幂等 `stop()`；每次 `start()` 创建独立 namespace，多实例互不干扰。内置三套帧 preset：`braille`（⠋⠙⠹…，默认）/ `dots`（⣾⣽⣻…）/ `bounce`（▏▎▍…）；`opts.frames` 可完全自定义。关键选项：`interval_ms`（默认 80ms）、`hl`（默认 `'Comment'`）、`hl_mode`（默认 `'combine'`，透明背景）、`prefix`、`virt_text_pos`

- **exec**：按文件类型解析执行命令（`vv-utils.exec.resolve(path, opts?)`）。优先级 **shebang（`/usr/bin/env` 透传）> 扩展名运行器优先级**，取首个 `executable()` 的运行器，返回 `{cmd, runner}` 纯数据（无副作用，运行交给调用方）。内置 `sh/bash/zsh/fish · ts/tsx/mts/cts · js/mjs/cjs · py · lua · rb · pl · php` 默认；`opts.runners` 深合并可增减扩展名 / 改优先级，`opts.shebang=false` 关 shebang
- **git.root / git.root_async**：探测 git 仓库根（rev-parse --show-toplevel），同步 + 异步两版
- **timer.debounce / timer.throttle 增加 `cancel` 句柄**：现返回 `(wrapped, cancel)`（向后兼容，旧 `local f = debounce(...)` 行为不变）。两者内部创建常驻 uv timer，过去无对外 close 接口 → 反复创建却不关闭会泄漏 timer 句柄。`cancel()` 幂等 `stop`+`close`，供调用方在不再使用时释放（如 vv-explorer 过滤 prompt 关闭时）

- **fs.realpath**：把路径解析到「真实路径」，用于跨来源路径比对（symlink 一致性）。`uv.fs_realpath` 解析所有中间符号链接；路径不存在时（已删除 / 父级回溯）解析「最长存在的祖先」再拼回剩余段，使已删文件与其 buffer name（解析形）仍可对齐；完全无法解析则退回 `vim.fs.normalize(fnamemodify(':p'))`。解决 `vim.fs.normalize` / `fnamemodify(':p')`（保留 symlink 形）与 `nvim_buf_get_name`（已解析真实路径）口径不一致导致的「同一文件两种路径串」漏命中

- **drop**：终端拖拽路径检测 + handler 分发（`vv-utils.drop`）。两条进入路径统一走 `dispatch(paths, pos)`：① 覆写 `vim.paste`，从 bracketed paste 检测绝对路径（`/`/`~` 开头，支持 shell-escaped / 引号 / `file://`），`pos=nil`（无坐标）；② **kitty DnD 协议（OSC 72，kitty ≥ 0.47）** 带落点 cell 坐标 + 拖拽移动事件流，`pos={x,y,op}`。`setup()` 启动探测（`t=q`），支持才 opt-in（`t=a`），移动回握手 `t=m:o=1`，drop 后拉 `text/uri-list`；不支持（含 tmux 内，tmux 不透传入站 OSC）静默回退路径 ①。`register(handler)` 签名扩为 `fun(paths, pos)`；新增 `on_drag(cb)` 订阅移动/离开（实时高亮落点用）；`setup({ kitty_dnd=false })` 关协议。内置默认 handler：Normal + 普通 buffer 下 `:edit` 打开文件。已验证：Kitty (Linux/macOS，含 DnD 落点)、Ghostty (Linux/GTK4)、Alacritty；已知限制：Ghostty macOS (AppKit) 不走 bracketed paste 无法拦截；kitty 落点需 nvim 直跑 kitty（脱 tmux）

- **animate**：通用补间动画引擎（`vv-utils.animate`）。`add(from, to, cb, opts?)` / `del(id)` — uv_timer 驱动，支持 id 去重、int 取整、5 种内置 easing（linear / outQuad / outCubic / inQuad / inOutQuad）、duration 双模式（step_ms / total_ms）

### Changed

- **diagnostics.symbol_for：诊断徽标改用 `vv-icons` 图标 + `Diagnostic*` 高亮**：`symbol_for(counts)` 仍只按最高 severity 返回一个 `{ glyph, hl }`，但优先从 `vv-icons` 读取 `diagnostics_error/warn/info/hint`，颜色直接沿用 `DiagnosticError/Warn/Info/Hint`。未安装 `vv-icons` 时保留旧的 `E/W/I/H + VVDiag*` fallback，避免独立消费 vv-utils 的插件硬依赖图标库
- **git：`VVGitRenamed` 配色 `#73c991` → `#4ec9b0`（青绿）**：原亮绿与 `VVGitUntracked`（同 `#73c991`）、`VVGitAdded`（`#81b88b` 灰绿）同属绿色系，R/C 状态在面板里难分辨。改青绿后三者拉开区分。色值是所有 vendor（vv-explorer / vv-git / statuscol）git 状态色的单一真相来源，一处改全局生效
- **sys.open_default：补错误处理 + 返回值**：`vim.ui.open` 失败（无可用 opener，如纯 headless / 无 GUI 的 SSH）时 `vim.notify` 报错而非静默吞错，并返回 `boolean ok`（向后兼容，旧调用忽略返回值即可）。文档明确语义：目录→系统文件管理器、文件→默认程序
- **sys.open_default：niri 焦点跟随**：niri 默认丢弃应用的 xdg-activation 聚焦请求（如已开 Firefox 里开新标签不抢焦点）。`$NIRI_SOCKET` 存在时，打开后异步经 `xdg-mime` 解析默认处理程序、轮询 `niri msg --json windows` 按 app_id（标题含文件名优先）定位并 `focus-window` 聚焦回来；非 niri 环境完全无副作用
- **help_panel：action 名 snake_case → 空格分隔**：渲染时自动将 `cd_to` 显示为 `cd to`，不影响 actions 表查表逻辑
- **help_panel：`<C-X>` → `<C-x>` 归一化**：Neovim 对 Ctrl 键统一存大写，渲染时还原为小写（Ctrl 不区分大小写）；`<M->`/`<S->` 保持原样

### Fixed

- **lsp.code_actions**：不再把 `textDocument/codeAction`、`codeAction/resolve` 的等待失败或 LSP `ResponseError` 静默折叠为 `no_quickfixes`；失败客户端立即停止后续请求，瞬时 timeout/interrupted 仅在整体 deadline 内重试，任一终局错误都会阻止部分编辑落盘
- **lsp.fix**：二进制文件在内容嗅探前仅读取 4KB 并检查 NUL，避免“前 100 行”意外读入无换行的大文件

- **format.apply_to_buffer：nvim_buf_set_lines 前判 modifiable，nomodifiable/只读 buffer 上不再抛 E21，改友好 WARN 返回**
- **drop.try_resolve_path：先按原始路径 fs_stat、未命中再 shell_unescape 后备，不再误删 Kitty 等原始路径里的字面反斜杠**
- **animate：缓动循环从 i=0 起（d=step_count-1），首帧等于 from，消除动画起步突变**
- **fs.exists：改用 fs_lstat（不跟随软链），broken symlink 不再被判为不存在，rename/create/unique_dest 的冲突检查不再被越过而静默覆盖软链**
- **fs.read_all：循环补读到读满/EOF，修复 fs_read 短读（>2GB / 网络 FS / 信号中断）时静默返回截断内容**
- **fs.sync_buffers：`nvim_buf_set_name` 包 pcall，目标名已被其它 loaded buffer 占用（E95）时不再冒泡中断调用方的后续 UI 刷新**
- **fs.copy：dst 位于 src 子树内时硬报错，杜绝复制目录进自身导致的无限递归（写满磁盘）**
- **fs.copy：新增 `st.type == 'link'` 分支，软链照原样重建（`fs_readlink` + `fs_symlink`）而非跟随复制目标。修复递归复制含「指向目录的软链」子项时 `fs_copyfile` 报 EISDIR 整树失败、半拷贝残留的问题**
- **fs.rename（EXDEV 降级）：跨分区移动/回收软链不再被物化成「目标字节的普通文件」**：原 copy+delete 降级走 `fs_copyfile` 跟随软链、把目标内容拷成普通文件再删原链，与同分区 `fs_rename`（保留软链）行为按文件系统边界静默分叉；现复用 fs.copy 的 link 分支，跨分区也保留软链及其（相对/绝对）目标
- **help_panel：collect() 把未列入 `categories` 的孤儿 `cat` 重映射到 'Other'**：actions meta 可声明任意 cat，但渲染只遍历 `ordered_cats`，某 cat 仅出现在 meta、未在 `categories` 声明时整段 keymap 被静默丢弃（违反文档「未提及的分类归入 'Other'」契约）；现在插入前兜底到始终渲染的 'Other' 桶，`key_w` 也只计可见行
- **timer.throttle：fn 抛错后 `running` 永久卡死、节流彻底失效**：`fn` 未 pcall 且在「启动复位 timer」之前同步调用，一旦抛错控制流逃逸 → 复位 timer 永不 `start`、`running` 永远停在 true，之后所有调用都被开头的 `if running then return` 挡掉。改为**先安排复位 timer 再调 `fn`**：fn 抛错仍向上传播（与原行为一致），但 `running` 必在 `limit` 毫秒后复位、节流自动恢复

### Added

- **fs.load_json / fs.save_json**：通用 JSON 持久化工具，支持文件路径读写和 JSON 字符串解析，文件不存在自动返回空表，父目录不存在自动创建
