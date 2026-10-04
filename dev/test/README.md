# vv 插件开发测试入口

这里管理开发测试环境，不由 `lua/vv-utils` 加载。普通用户安装 vv-utils 时只下载这些脚本；不会下载 mini.test，也不会运行测试

仅支持 Unix-like 系统（macOS / Linux 等）。依赖：Neovim 0.12+、Git、POSIX shell。插件自己的运行时外部依赖仍需准备，例如 vv-replace 使用 ripgrep

## 运行

从任意工作目录执行：

```sh
sh /path/to/vv-utils.nvim/dev/test/run.sh /path/to/plugin.nvim
sh /path/to/vv-utils.nvim/dev/test/run.sh /path/to/plugin.nvim 'debounce'
```

第二个参数是可选的**字面子串**，匹配 `文件路径 | 用例名称`，不是 Lua pattern。没有匹配的用例是失败，不会静默通过

各 vv 仓库均提供薄入口，例如：

```sh
sh /path/to/vv-replace.nvim/tests/run.sh
sh /path/to/vv-replace.nvim/tests/run.sh test_panel_state
VV_UTILS=/path/to/vv-utils.nvim NVIM_BIN=/path/to/nvim sh /path/to/vv-replace.nvim/tests/run.sh debounce
```

`VV_UTILS` 用于显式指定共享工具/运行时库；vv-utils 入口默认取本仓，其余插件入口默认取兄弟仓库 `vv-utils.nvim`。CI 或其他开发者先检出这两个仓库（固定各自版本），然后使用相同命令，不依赖个人 Neovim 配置。此入口不负责下载 vv-utils 或任意业务依赖

## 默认发现与覆盖

已有依赖安装好后，直接运行各仓 `tests/run.sh`，不必逐次填写路径。共享入口在隔离前保存现有 runtime 位置；各仓 `tests/env.sh` 声明自身的源码/工具链默认值，共享层不硬编码插件依赖：

- `VV_TEST_SITE` 默认 POSIX 数据目录 `${XDG_DATA_HOME:-$HOME/.local/share}/${NVIM_APPNAME:-nvim}/site`，只读接入 parser/queries，不加载个人配置
- 图标源码默认兄弟仓库 `vv-icons.nvim`；Git 用 `VV_ICONS`，其余使用方用 `VV_TEST_ICONS`
- symbols 的 `VV_TEST_SPLITS` 默认兄弟仓库 `vv-splits.nvim`
- i18n 的 `VV_TEST_PARSERS` 默认 `VV_TEST_SITE`
- task-panel 在隔离 HOME 前用 `rustup which cargo` 查询已安装工具链；`VV_TEST_TOOLCHAIN_BIN` 可覆盖，非 rustup 的真实可执行文件也可由 PATH 提供

非空环境变量始终优先；源码覆盖路径相对调用者 cwd 解析并规范化。缺失声明的目录会明确报出变量名和路径并返回非零，不自动下载插件、parser 或工具链，也不把缺依赖当作测试通过

`tests/env.sh` 在 Neovim 启动前由共享 shell 入口加载，只应设置依赖环境变量，不运行被测行为或安装程序。入口导出绝对 `VV_TEST_REPO`，并提供 `vv_test_source_path ENV_NAME DEFAULT_DIR`：返回现有源码目录的规范路径，空值采用默认目录，目录缺失返回非零。文件不进入 Lua 用例发现

## 下载和版本

- mini.test 来自独立仓库 <https://github.com/nvim-mini/mini.test>
- 固定 commit 由 `deps.lua` 统一管理；升级时修改 commit 并复验调用仓库
- 默认下载位置：`${XDG_CACHE_HOME:-$HOME/.cache}/nvim-test-deps/mini.test/<commit>/`
- `VV_TEST_DEPS_CACHE=/path/to/cache` 可以改变 `nvim-test-deps` 根目录
- 首次显式测试才下载，相同 commit 共享缓存。下载使用临时目录，成功后原子发布，不原地切换已发布版本
- 缓存目录受开发者控制，命中时信任其中 `lua/mini/test.lua`；文件损坏时删除该版本目录后重跑。不自动更新分支，不提供任意版本解析

共享入口在启动前保存依赖缓存位置，再将 HOME、TMPDIR、runtime 和 config/data/state/cache 四类 Neovim 持久目录指向本轮临时目录。scratch 使用显式模板，服从调用者 TMPDIR；退出后清理本轮目录，mini.test 的共享缓存保留

## 用例契约

`tests/**/test_*.lua` 必须返回 `MiniTest.new_set()`，通过具名字段添加真实用例。测试加载阶段不要执行被测行为。mini.test API 见 <https://nvim-mini.org/mini.nvim/doc/mini-test.html>

窗口、buffer、timer 与模块状态相关测试可使用 `MiniTest.new_child_neovim()`，每个 case 启动全新子进程。case 的 cwd、HOME、XDG 和 TMPDIR 必须在 child 启动前隔离，连接失败也还原父环境；`post_case` 关闭并清理独立 fixture。vv-utils 的 `tests/helpers.lua` 展示了启动隔离和失败清理模式

需要回收外部 producer 时，可从 `VV_UTILS .. '/dev/test/process.lua'` 加载测试专用模块，在关闭 owning child **之前**调用 `stop_descendants(child_pid)`，回收当前父子关系下的后代；只传入本测试实际创建的 PID，查询或清理失败必须令用例失败。这不保证回收自行脱离进程树的 daemon，tmux 等独立服务仍须用本 fixture 的 socket 显式停止

共享 runner 在执行 case 前初始化 parent 的 RPC socket 临时目录，按 suite 生命周期持有；不要让首个 case 的 fixture 清理删除 parent 缓存的 tempname 目录，否则后续 case 会出现 `E5431`

同步 RPC 函数内的断言错误会传回父进程并记录为用例失败。异步回调应收集结果或显式 `pcall` 记录错误，再在等待结束后断言；不要假设框架自动捕获任意 scheduled callback 的异常。试点还在清理后检查子进程 `v:errmsg`，作为额外错误信号，不替代异步结果断言

收集错误、下载失败、空集合、用例或 hook 失败均返回非零。套件事件循环等待上限为 300 秒，**不能打断阻塞的同步 RPC 或无限循环**；CI 应配置 job timeout。插件行为等待仍必须使用自己的条件与有限超时

## 设施自身回归（隔离独立入口）

本设施自测不从插件测试集合中收集，可直接运行，不要求个人 Neovim 配置、兄弟插件仓库或预热缓存：

```sh
cd /path/to/vv-utils.nvim
./dev/test/selftest/run.sh
# 可显式选择缓存和 Neovim；缓存已备齐时不联网
VV_TEST_DEPS_CACHE=/path/to/nvim-test-deps NVIM_BIN=/path/to/nvim \
  ./dev/test/selftest/run.sh
```

额外要求 Bun 和 POSIX `ps`。首次运行会使用 `deps.lua` 获取固定版本 mini.test，需要网络；行为 fixture 启动前将缓存复制到隔离目录，并用 Git 拦截器禁止用例联网或修改 Git 状态。预期 `5 PASS / 0 FAIL`，正常与失败运行都清理 fixture；`KEEP=1` 仅保留隔离副本与最后一次证据 JSON，不保留在途进程或 scratch

五组黑盒验证捕获的真实失败：

- 断言、清理 hook、collect 和 RPC 子进程异常退出被错误报为成功；hook 失败后仍必须释放子进程
- 空集合或无字面匹配被错误报为成功
- 递归 named sets / 字面过滤退化、依赖兄弟目录或个人配置、四类持久目录写入泄漏。真实文件与 `vv-utils.state` 写后读回，连续两次运行验证隔离与退出清理
- 直接入口没有接入仓库依赖声明、在 HOME/XDG 隔离后才找现有 runtime、覆盖值被默认源码吞掉，或缺依赖仍执行用例/误报成功。实际加载 fixture 源码验证默认值、带空格的相对覆盖路径与明确失败
- 阻塞 RPC 无法被内部事件循环超时中断：外层墙钟截止必须终止真实阻塞子进程

每次入口调用由外层设 15 秒墙钟截止；故意阻塞场景为 2 秒。超时清理包含 Neovim 独立 session 的后代（只杀 shell 进程组不足），并由外层删除无法执行 shell trap 的 scratch。慢速 CI 可导致此开发套件超时失败；这不是共享 runner 的 300 秒行为超时

调用方定向复验（先固定调用方文件快照，避免依赖并行编辑中的瞬时版本）：

```sh
VV_UTILS=/path/to/vv-utils.nvim NVIM_BIN=/path/to/nvim \
  sh /path/to/vv-replace-snapshot/tests/run.sh test_history
```

真实调用方复验仍需外层墙钟/CI job timeout。共享 runner 的 300 秒等待**不能中断同步阻塞 RPC**，并未因新增自身套件而改变；CI 超时必须终止整棵后代进程并清理其 fixture，而非只终止父 shell

vv-utils 全套测试：

```sh
sh /path/to/vv-utils.nvim/tests/run.sh
sh /path/to/vv-utils.nvim/tests/run.sh '取消压制已排队结果'
```

vv-utils 的薄入口默认 `VV_UTILS` 为本仓。诊断图标源码默认兄弟 `vv-icons.nvim`，可通过 `VV_TEST_ICONS` 覆盖；其它 fixture 与依赖边界见 [vv-utils 测试 README](../../tests/README.md)。共享 finder 仍只发现 `tests/**/test_*.lua`，调用契约不变

headless 覆盖 API 和状态，不证明真实终端中的鼠标、视觉和完整配置交互
