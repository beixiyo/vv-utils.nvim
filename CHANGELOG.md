# Changelog

## 0.8.0 - 2026-10-04

### Breaking

- **loading**：移除 `start`，改用 `mark`；`ticker` 改为返回 handle，停止时调用 `handle:stop()`
- **loading**：`interval_ms` 必须为 >= 1 的整数，`frames` 必须为非空字符串列表
- **loading.ticker**：`on_frame` 抛错改为捕获，不再抛给调用方

### Added

- **fs.close_stale_buffers**：关闭指向已删除文件的未修改 buffer
- **bufdelete.replace_in_windows**：替换窗口中显示的 buffer，但不删除原 buffer
- **file_operations**：新增 `will_rename_many_async` / `notify_did_rename_many`，批量合并 LSP 文件改名
- **loading.mark**：支持列号、多处共用 handle，以及 `label_hl` 分段上色
- **loading.win_text**：在浮窗 title / footer 显示动画，停止时恢复原文与高亮，窗口关闭时自动停止
- **loading.slot**：并发请求共用显示，计数归零才隐藏，旧请求释放不影响新请求
- **loading.blocking**：同步执行前显示静态帧或 echo，透传返回值并在抛错时清理
- **loading.ticker**：`on_frame` 返回 false 时停止
- **sys.tmux_clients**：逐个判断 tmux 客户端是否经 SSH / mosh 远程连入
- **timer.throttle**：新增 `opts.trailing`，在节流窗口结束时补执行最后一次调用
- **mouse.redispatch_outside**：面板外鼠标事件切换窗口后可重映射重发
- **ui_window.key_hints**：把按键提示渲染为浮窗 title / footer chunks
- **ui_peek**：新增底部按键提示 `hints`（默认 `false`）与 `footer_pos`（默认 `'center'`）
- **tree_panel**：新增节点 `navigable`（默认 `true`），设为 `'folded'` 时展开分组行会被 `j` / `k` 跳过
- **fs**：新增事务 `apply_async` / `undo_async` 与分片递归删除 `delete_async`
- **ui_columns**：新增不开窗口的文字对比排版器
- **path.collapse_middle**：新增 `max_width`，默认 nil 不限宽

### Changed

- **fs.sync_buffers**：改名后重读未修改的普通文件 buffer，清除 notedited，避免 `:w` 报 E13
- **fs.sync_buffers**：重读触发 BufReadPre/Post、FileType 等 autocmd 并丢失折叠，但保留编码、文件格式、readonly、视图与 undo，补附着手动启动的 LSP client
- **loading**：实例共享时钟、帧同步，无订阅者时释放；`ticker.on_frame` 新增第二个参数 `label`
- **sys.is_remote / is_remote_async**：远程判据与 `~/.local/bin/remote-session` 对齐
- **ui_peek**：`hl.range` 默认值由 `Search` 改为 `CurSearch`

### Fixed

- **fs.sync_buffers**：修复 buffer 改名后 LSP 未同步、旧路径收不到 didClose
- **keys.display**：`<Bslash>` / `<Bar>` 正确显示为 `\` / `|`
- **prompt**：spinner 自行停止后，再次 `set_busy(true)` 可以重建动画
- **sys.is_remote_async**：判定或 callback 抛错不再被静默吞掉；命令超时 500ms 后 SIGKILL 并按失败处理，不再无限等待回调
- **sys.is_remote / is_remote_async**：被信号终止的命令按失败处理，不再解析不完整输出
- **sys.is_remote / tmux_clients**：命令超时返回 nil 时不再抛错，按失败处理；`ps` 不可用时仍以环境变量兜底

## 0.7.0 - 2026-09-30

### Added

- **ui_peek**：新增通用内容浮窗，支持自绘行、纯文本和文件快照、动态尺寸与锚点、语法和落点高亮，默认显示原生行号；尺寸支持 `{ ratio = n }`

## 0.6.2 - 2026-09-26

### Added

- **sys.is_remote / is_remote_async**：判断是否为 SSH 远程
- **fs.write_all**：新增 `fsync`（默认 `true`），可关闭断电持久化

### Changed

- **state**：锁文件与状态文件不再 fsync，相同值跳过写入，提升写盘速度
- **行尾句号清理**：支持块注释结束符前的句号，以及围栏代码块中的注释行

## 0.6.1 - 2026-09-12

### Changed

- **tree_panel**：支持底部工具栏

### Fixed

- **tree_panel**：修复 LuaDoc 高亮

## 0.6.0 - 2026-09-07

### Added

- **modal**：新增通用多动作浮窗，`confirm` 复用同一交互与生命周期
- **state**：新增跨 Neovim 实例共享的原子持久化状态，支持 compare-and-swap、文件订阅与跨进程锁
- **ui_rows / tree_panel**：支持多行逻辑项渲染、导航、激活与刷新

### Changed

- **fs.realpath**：统一解析符号链接、断链叶节点、相对目标和已存在祖先

### Fixed

- **state**：修复 `false` 值 compare-and-swap、订阅初始化、符号链接锁分裂与过期锁回收竞争
- **tree_panel**：修复多行节点导航重复停留、刷新偏移与 header / footer 方向计算

## 0.5.11 - 2026-09-02

### Added

- **git**：新增七种 unmerged 状态识别，以及普通、diff3、zdiff3 冲突块解析 API
- **diff_lines**：支持同一路径的 index stage 成对比较和行号投影，路径按 `root` 解析，缺失 stage 时回调 `nil`

### Changed

- **冲突标记**：只匹配恰好七个标记字符且后接行尾或空格的行，避免误判分隔横幅与紧跟文本的行

## 0.5.10 - 2026-08-19

### Added

- **tree_panel**：新增声明式固定多行 toolbar

## 0.5.9 - 2026-08-18

### Fixed

- **keymap**：规范化特殊键表示，修复控制键因所有权比对失败而残留

## 0.5.8 - 2026-08-16

### Added

- **callback.limit**：限制回调调用次数，透传返回值并支持幂等失效
- **process.start**：统一进程启动失败处理、主循环回调、物理取消与取消后的回调压制
- **archive**：新增跨平台 tar 归档列表与解压
- **fs**：新增 `is_directory` / `is_dir_empty`，`write_all` 支持指定新建父目录权限 `directory_mode`
- **fs.temp**：新增 `write` / `create` / `cleanup`，独占创建受限临时文件并幂等清理
- **http**：新增可超时、可取消的非流式 HTTP 请求、query 编码与 URL 参数拼接，避免请求敏感信息进入进程参数

### Changed

- **git / path_completion / download**：统一进程启动与取消语义
- **history**：采用原子写入，保持文件 `0600`、新建目录 `0700` 权限

### Fixed

- **download**：取消后等待进程退出再补清理，避免 Windows 残留临时文件

## 0.5.7 - 2026-08-12

### Changed

- **help_panel**：新增 `icon_hl` / `title_icon_hl`，未配置时保持原高亮；标题按内容宽度居中
- **keys**：单字母大写键位展示为 `⇧` 前缀，与显式 `<S-...>` 一致

## 0.5.6 - 2026-08-10

### Added

- **confirm**：新增支持详情、危险级别、可配置按键与语义高亮的确认浮窗
- **transaction**：新增与业务无关的事务机制
- **keys**：新增统一键位展示与提示格式化

### Changed

- **exec**：新增 rust、go、zig 等解析
- **help_panel / input**：统一使用 `keys` 展示键位

## 0.5.5 - 2026-08-08

### Fixed

- **scroll**：终端括号粘贴期间不再损坏内容

### Added

- **scroll.pasting**：查询终端粘贴保护状态

## 0.5.4 - 2026-08-07

### Added

- **fs**：新增目录统计 `inspect_dir` / `scan_dir` / `dir_info_lines`，分片扫描支持截断、限深与取消，不跟随符号链接
- **fs.file_info_highlight**：新增 `pending` / `truncated` 分组与状态标记，区分扫描中、截断和最终结果

## 0.5.3 - 2026-08-03

### Added

- **async.Scope**：新增请求生命周期管理，支持 `latest` / `parallel`、过期结果校验、invalidate / cancel / dispose 与一次性资源释放

### Changed

- **文档**：模块用法与 API 说明移至各模块目录的 `README.md`

## 0.5.2 - 2026-08-01

### Added

- **git.highlight_specs**：返回共享 `VVGit*` 高亮基准的隔离副本，支持安全叠加配置与重复 setup 恢复默认值

## 0.5.1 - 2026-07-30

### Added

- **fs**：新增文件探测 `inspect_file` / `is_binary` 与信息展示 `file_info_lines` / `highlight_file_info`

### Changed

- **format.project**：二进制判断复用 `vv-utils.fs`
- **exec**：未知文件类型与缺少 runner 的错误提示统一为英文

## 0.5.0 - 2026-07-29

### Added

- **completion / blink**：新增 buffer-local 补全 descriptor 与可选 `vv-utils.blink` source
- **glob / path_completion**：新增框架无关的 `compile` / `compile_list` 结果

### Changed

- **path_completion**：候选默认上限由 200 改为 50，递归 `fd` 扫描预算改用 `scan_max_items`（默认 1000），不再由 `max_items * 20` 决定
- **path_completion / blink**：支持异步补全与取消，目录分批扫描，递归 `fd` 不再同步等待
- **glob**：`compile_rg` / `compile_rg_list` 改为通用编译结果上的 ripgrep adapter

### Fixed

- **prompt**：跨行删除与空输入 Backspace 不再越过输入行，空 icon 不再留下多余空格

## 0.4.3 - 2026-07-29

### Added

- **hl.register_dimmed**：从现有高亮派生低对比度颜色，`ColorScheme` 后重新计算，原模块入口保持兼容
- **color**：新增 `parse` / `to_hex` / `to_integer` / `mix` / `composite`，支持 Neovim RGB 整数、RGB(A) 十六进制与 RGBA 对象

## 0.4.2 - 2026-07-28

### Fixed

- **fs.rename**：大小写不敏感文件系统上的纯大小写改名不再误报目标存在，仍拒绝覆盖不同文件

## 0.4.1 - 2026-07-27

### Added

- **keymap**：新增 buffer-local 映射 `attach` / `refresh` / `detach`，按条件接管并仅恢复自身持有的映射，保留用户重绑，buffer 销毁时自动清理

## 0.4.0 - 2026-07-27

### Changed

- **lsp.code_actions**：并行请求全部客户端，Code Action 与 resolve 共用截止时间，超时取消未完成请求
- **lsp.fix.check_path_support**：创建临时 buffer 前检查 filetype、配置与可执行文件，缺少支持时立即返回结构化错误

### Breaking

- **lsp.fix**：删除 `supports_path(path, configs?)`，改用返回 `(supported, error?)` 的 `check_path_support(path, configs?)`

## 0.3.3 - 2026-07-26

### Changed

- **path.find_root**：新增项目根解析，优先上层 `.git`，再回退至最近的包管理或构建 manifest；`get_root` 复用该逻辑

## 0.3.2 - 2026-07-26

### Added

- **state**：新增按插件与功能隔离的 JSON 状态仓库，合并最新磁盘快照，以 `0600` 原子保存，拒绝覆盖损坏文件
- **tree_panel**：新增通用树形侧栏，支持左右布局、稳定折叠、自定义渲染与键位、固定 winbar、语法高亮、预览跳转和持久宽度
- **input**：新增输入行装饰器，渲染 label、placeholder 与键位提示，输入值和生命周期由调用方持有

### Changed

- **prompt**：复用 `input` 渲染，保留既有浮窗与过滤生命周期
- **fs**：JSON 读写支持严格解码与显式文件权限
- **drop**：处理器和拖拽监听返回幂等 disposer，新增 teardown 释放 Kitty 监听并按 ownership 还原 `vim.paste`
- **scroll**：新增 disable，取消动画并仅还原自身持有的映射与 `mousescroll`

## 0.3.1 - 2026-07-19

### Changed

- **文件事务迁移**：删除 `vv-utils.fs_transaction` 入口，改用 `vv-utils.fs.new_transaction()`

## 0.2.1 - 2026-07-19

### Added

- **path_completion**：新增独立路径候选引擎，支持逗号分段、Include / Exclude / Cwd、含空格路径与 glob 转义，并可按需通过 `fd` 补全深层路径，无常驻索引

## 0.2.0 - 2026-07-19

### Added

- **glob**：新增 VS Code 风格搜索 glob 编译，支持逗号拆分、brace、字符类、转义、`./` 锚定与 `!` 排除，同时匹配路径及目录后代
- **fs_transaction**：新增独立文件内容事务，支持原子写入、校验、失败回滚与单层撤回，默认拒绝覆盖未保存 buffer

## 0.1.0 - 2026-07-13

### Added

- **lsp.fix**：新增 LSP 自动修复引擎，支持客户端启动等待、Code Action 收敛、单文件原子应用与临时 buffer 清理，`files` 异步串行处理多文件
- **mouse.block_visual_drag**：阻止 nofile 面板鼠标拖拽或多击进入 Visual，包括跨窗口操作
- **bigfile.is_big**：公开按字节数、平均行长或已有 bigfile 标记判定大文件的谓词
- **loading.start**：新增 buffer 行内动画，返回幂等停止函数，支持独立多实例、内置帧与自定义帧
- **exec.resolve**：按 shebang 优先、扩展名次之选择首个可用 runner，仅返回命令数据，不执行
- **git.root / root_async**：新增同步与异步 Git 根目录探测
- **timer.debounce / throttle**：返回 `(wrapped, cancel)`，兼容旧调用；幂等 `cancel()` 用于释放 timer
- **fs.realpath**：解析符号链接及最长存在祖先，使已删除文件与 buffer 路径仍可一致比对
- **drop**：新增终端拖拽路径分发，覆写 `vim.paste` 检测路径，普通 buffer 的 Normal 模式下默认打开文件；Kitty ≥ 0.47 支持落点与移动事件，`register` 接收 `(paths, pos)`，新增 `on_drag`，可用 `kitty_dnd=false` 关闭协议
- **drop 兼容性**：Kitty 落点需脱离 tmux，不支持协议时回退粘贴检测；Ghostty macOS 不走 bracketed paste，无法拦截
- **animate**：新增 `add` / `del` 补间动画，支持去重、取整、内置 easing 与步长或总时长模式
- **fs.load_json / save_json**：新增 JSON 读写与字符串解析，文件不存在时返回空表，自动创建父目录

### Changed

- **diagnostics.symbol_for**：优先使用 `vv-icons` 与 `Diagnostic*` 高亮，未安装图标库时保留 `E/W/I/H + VVDiag*` fallback
- **git**：共享 `VVGitRenamed` 配色由 `#73c991` 改为 `#4ec9b0`，区分重命名与新增、未跟踪状态
- **sys.open_default**：打开失败时通知报错并返回 `boolean ok`；niri 环境打开后异步聚焦默认程序，非 niri 无额外副作用
- **help_panel**：action 名中的下划线显示为空格，Ctrl 键展示归一为小写，不影响查表

### Fixed

- **lsp.code_actions**：请求失败不再误报 `no_quickfixes`，仅在总截止时间内重试瞬时错误，终局错误阻止部分编辑落盘
- **lsp.fix**：二进制嗅探仅先读取 4KB，避免无换行大文件被大量读入
- **format.apply_to_buffer**：不可修改 buffer 不再抛 E21，改为 WARN 返回
- **drop.try_resolve_path**：优先检查原始路径，避免误删文件名中的字面反斜杠
- **animate**：首帧等于起始值，消除起步突变
- **fs.exists**：正确识别断链，避免冲突检查漏过并覆盖软链
- **fs.read_all**：补读至读满或 EOF，避免短读返回截断内容
- **fs.sync_buffers**：目标名被 loaded buffer 占用时不再抛错中断后续刷新
- **fs.copy**：拒绝复制目录到自身子树，软链原样复制，避免递归失控或整树复制失败
- **fs.rename**：跨分区移动软链时保留链接及目标，不再物化为普通文件
- **help_panel**：未声明的分类归入 `Other`，不再丢失对应快捷键
- **timer.throttle**：回调抛错仍向上传播，但节流窗口结束后恢复，不再永久失效
