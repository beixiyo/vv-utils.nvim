# vv 插件共享开发测试设施

[English](README.md) | 中文

本目录仅供开发测试，不由生产 `lua/vv-utils` API 加载。要求 Unix-like 系统、Neovim 0.12+、Git、POSIX shell。插件自己的外部工具和集成依赖由调用仓声明，不由 runner 安装。Bun 仅用于设施自测

## 入口

```sh
./tests/run.sh [literal-filter]
sh /path/to/vv-utils.nvim/dev/test/run.sh /path/to/plugin.nvim [literal-filter]
VV_UTILS=/checkouts/vv-utils.nvim NVIM_BIN=/path/to/nvim ./tests/run.sh
```

可从任意 cwd 运行。过滤匹配 `文件路径 | 用例名` 的字面子串，不是 Lua pattern。无匹配、空集合、收集错误、下载错误、用例或 hook 失败均非零退出

**消费者 canonical launcher**：将 [`launcher.sh`](launcher.sh) 原样复制为消费者 `tests/run.sh`，执行 `chmod +x tests/run.sh`。默认 `tests/` 直接位于插件根；只有不同布局才调整 `repo=.../..` 一行。模板仅查找已有的含 `dev/test` 的 utils 并交给共享入口，不下载插件，不加载个人 init/管理器。utils 自身使用本仓短入口，默认本仓，仍支持 `VV_UTILS` 覆盖

## 发现与覆盖

非空显式源码变量最高优先；错误覆盖明确报变量/路径/缺失标记并失败，绝不 fallback。相对路径（含空格）相对启动者原 cwd 解析，在 HOME/XDG/cwd 隔离前冻结。每个已选依赖路径和来源在 stderr 打印一次

`vv_test_dependency VAR PLUGIN_NAME MARKER...` 的发现顺序：

1. 显式 `VV_TEST_VENDOR_ROOT/PLUGIN_NAME` → 被测仓的兄弟 `PLUGIN_NAME` → 原 Neovim config 的 `vendors/PLUGIN_NAME`
2. `VV_TEST_LAZY_ROOT/PLUGIN_NAME`，默认原 data 的 `lazy/PLUGIN_NAME`
3. `VV_TEST_PACK_ROOT/pack/*/start/PLUGIN_NAME` → `pack/*/opt/PLUGIN_NAME`，默认根为原 data 的 `site`；最后补查原 config 的各 pack group

覆盖 vim.pack 官方路径 `data/site/pack/core/opt/PLUGIN_NAME`。`VV_TEST_PACK_ROOT` 是 **packpath entry**，不是 `pack/` 目录。三个根覆盖都是单一目录，支持空格；非空错误根立即失败。默认原目录按 `${XDG_CONFIG_HOME:-$HOME/.config}/${NVIM_APPNAME:-nvim}` 和 `${XDG_DATA_HOME:-$HOME/.local/share}/${NVIM_APPNAME:-nvim}` 得到。仅检查这些已知根/group，不递归扫描 HOME，不执行管理器配置。第一候选存在但不完整时失败，不落回旧安装副本；dirty 开发源码直接使用，不被缓存 checkout 替代

自定义安装目录名使用显式源码覆盖，例如 `VV_UTILS=/checkouts/renamed-utils`、`VV_ICONS=/checkouts/icons-dev`。CI 复现先自行 checkout 各依赖所需 revision，再传源码变量；版本固定由 CI/caller 负责，不新增插件下载器。独立消费者 clone 不包含 utils/集成依赖，缺失时明确提示安装/检出与覆盖方法

## `tests/env.sh` 声明 API

共享 shell 在隔离前 source，提供绝对 `VV_TEST_REPO`、`VV_TEST_CALLER_CWD`。只声明已有源码/runtime/工具链，不安装、不执行用例行为。以下函数成功返回 0，失败返回非零并输出 stderr：

- `vv_test_dependency VAR PLUGIN_NAME MARKER...`：发现已有插件目录并验证实际需要的相对入口文件/目录；赋值并导出绝对 `VAR`，无 stdout。至少声明实际模块入口标记
- `vv_test_path VAR DEFAULT_DIR MARKER...`：校验显式 `VAR` 或默认目录及标记；赋值并导出绝对 `VAR`，无 stdout。用于 parser/runtime/原生工具链目录
- `vv_test_runtime VAR`：校验已声明的目录并追加到导出的 `VV_TEST_RUNTIME_PATHS`，不递归 package、不加载模块
- 保留 `vv_test_source_path VAR DEFAULT_DIR [MARKER...]`：同样校验路径，但将绝对路径写 stdout，由 caller 赋值/export；兼容现有消费者与设施回归

```sh
vv_test_dependency VV_ICONS vv-icons.nvim lua/vv-icons/init.lua
vv_test_dependency VV_BUFFERLINE vv-bufferline.nvim lua/vv-bufferline/init.lua
vv_test_dependency VV_TEST_SPLITS vv-splits.nvim lua/vv-splits/init.lua
vv_test_path VV_TEST_PARSERS "$VV_TEST_SITE" parser/typescript.so parser/tsx.so
vv_test_runtime VV_TEST_PARSERS
# queries 可能位于已安装插件，不只在 site：
vv_test_dependency VV_TEST_QUERIES nvim-treesitter queries/typescript/highlights.scm
vv_test_runtime VV_TEST_QUERIES
```

沿用 caller 现有变量名（`VV_ICONS` / `VV_TEST_ICONS` 等），共享层不猜别名。标记必须对应当前平台与该套件实际所需文件。工具链策略留 env.sh：如在 HOME 隔离前用 `rustup which cargo` 查询，然后 `vv_test_path VV_TEST_TOOLCHAIN_BIN "$directory" cargo rustc`，加到 PATH。非 rustup 的原生 PATH 工具仍可用。utils 的 env.sh 提供实例

## Runtime、缓存与隔离

`VV_TEST_SITE` 默认原 data 的 `site`；显式值必须存在。默认 site 不存在时无 parser 需求的套件仍可运行；parser 用例必须声明/校验真实 parser 和 queries 标记，缺失不能 skip

`VV_TEST_RUNTIME_PATHS` 是可选的 **换行分隔** 已有 runtime 根列表；隔离前冻结为绝对路径，然后 env.sh 可追加。支持空格，不支持文件名内换行。parent runner 接入存在的 site 和这些精确根。每个 caller 的 child bootstrap 同样接入：

```lua
vim.opt.packpath = ''
dofile(vim.env.VV_UTILS .. '/dev/test/runtime.lua').apply()
-- 然后 prepend 已选业务依赖、utils、被测仓
```

不把 `site/pack` 或递归所有安装 package 塞入 runtimepath，不加载个人 init、lazy 或 vim.pack 管理器。选中的源码及 parser/query 根由 caller 在 child prepend，优先于默认 site 和内置 runtime；路径从 env 读取，不重猜兄弟目录

`VV_TEST_DEPS_CACHE` 默认 `${XDG_CACHE_HOME:-$HOME/.cache}/nvim-test-deps`，隔离前冻结。唯一自动准备的测试依赖是 mini.test：[`deps.lua`](deps.lua) 固定 commit，临时下载后原子发布。缓存命中信任 `lua/mini/test.lua`；损坏版本目录由开发者删除。不追踪浮动分支、不解析插件版本。离线运行需已有该固定缓存

`NVIM_BIN` 可为 PATH 名或可执行路径（含相对路径），在原 cwd 冻结。任何依赖准备前共享层清除导出的所有 `GIT_*`、禁用用户/系统 Git 配置与交互提示，并移除活动 TMUX/screen/Kitty/WezTerm/NVIM/VIM 会话变量。随后 HOME、TMPDIR、XDG config/data/state/cache/runtime 隔离到 scratch。scratch 显式模板服从原 TMPDIR（相对路径先按调用 cwd 冻结为绝对路径）。正常退出与 HUP/INT/TERM 清理 scratch；信号非零退出（129/130/143），清理本次 owning Neovim 的后代

## 具名用例与生命周期

`tests/**/test_*.lua` 返回具名 `MiniTest.new_set()`，收集只注册用例。窗口、buffer、timer、模块状态用每 case 全新 `MiniTest.new_child_neovim()`。child 启动前隔离 cwd/HOME/XDG/TMPDIR，连接失败也归还 parent 环境；失败 hooks 仍清理 fixture/child。[`tests/helpers.lua`](../../tests/helpers.lua) 为实例

外部 producer 用测试专用 [`process.lua`](process.lua) 的 `stop_descendants(child_pid)`，在停止 owning child **之前**执行。仅传本 case 创建的 PID；查询/清理失败必须令用例失败。脱离进程树的 daemon 不覆盖，如 tmux 服务必须用 fixture 专属 socket 清理。parent RPC temp 目录属于整个 suite，不可被首个 case fixture 清理

同步 RPC 断言错误回传 parent；scheduled callback 要收集错误/结果并有限等待，不假设框架捕获所有异步异常。runner 的事件循环上限 300 秒 **不能中断阻塞同步 RPC / 无限循环**。CI 必须加外层墙钟/job timeout，并在 SIGKILL 后清理整棵 owning 进程树与 scratch。headless 不代替真实 TUI 的鼠标/视觉/键位验证

## 设施黑盒回归

```sh
NVIM_BIN=/path/to/nvim VV_TEST_DEPS_CACHE=/path/to/nvim-test-deps \
  ./dev/test/selftest/run.sh
```

设施自测额外要求 Bun、POSIX `ps`。准备阶段可下载 pinned mini.test；行为 fixture 复制缓存并禁止网络/fetch，不依赖真实个人配置或兄弟仓。黑盒用例验证：断言/hook/收集/RPC 失败；空集合与无字面匹配；真实 state 写后读回与重复隔离；旧声明 API 和相对覆盖；真实 launcher 实际加载不同 dirty vendors、标准/自定义 lazy、native start/opt/core-opt、自定义命名覆盖；runtime/query 根传入真实 child；恶意 Git/终端环境；相对 TMPDIR 的隔离与真实写后读回；TERM 清理；外层终止真实阻塞 RPC。单次外层上限 15 秒（阻塞超时场景 2 秒）。`KEEP=1` 仅保留隔离 fixture/证据，不留运行进程

utils 全套：`./tests/run.sh`；实际前提与场景边界见 [utils 测试说明](../../tests/README.md)
