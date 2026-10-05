# vv-utils tests / 开发测试

## English

Run `./tests/run.sh [literal-filter]` from any cwd (Neovim 0.12+, Git and POSIX shell). Literal filters match file paths or named cases; no matches fail. Utils defaults to this checkout, with explicit `VV_UTILS` / `NVIM_BIN` overrides. Diagnostic fixtures need existing vv-icons sources, resolved by the shared discovery contract (`VV_TEST_ICONS` override). No personal init or plugin manager is loaded.

Full suite also requires `tar`, `fd`, `mkfifo`, `ps`, `chmod`, writable `/tmp`, a non-root user for real permission failure cases, and a working native Cargo/rustc toolchain for `cargo metadata --no-deps` (no build/download). `tests/env.sh` queries rustup before HOME isolation; `VV_TEST_TOOLCHAIN_BIN` overrides its native bin directory, or non-rustup native PATH tools can be used. Execution/download scenarios inject local executable fixtures, never real remote downloads. Infrastructure self-tests additionally require Bun and a prepared pinned mini.test cache for offline runs.

Each case uses a fresh child, isolated cwd/HOME/XDG/TMPDIR and failure-safe process/fixture cleanup. Parent and child use the same frozen absolute dependency/runtime paths; child calls `dev/test/runtime.lua`. Git writes happen only in temporary fixtures, never in source checkouts. Headless results do not prove TUI interaction. CI needs an outer timeout because synchronous blocking RPC cannot be interrupted by the runner's event-loop timeout.

Dependency declarations, canonical launcher, runtime integration, isolation, cache preparation and black-box regressions: [shared English contract](../dev/test/README.md) / [中文契约](../dev/test/README.zh-CN.md).

## 中文

`tests/**/test_*.lua` 返回 pinned `mini.test` 的具名集合，收集时只注册场景与 hooks
`tests/run.sh` 是共享 [dev/test](../dev/test/README.zh-CN.md) 的薄入口，默认 `VV_UTILS` 为本仓；不加载个人配置

```sh
./tests/run.sh
./tests/run.sh '取消压制已排队结果'
VV_UTILS=/path/to/vv-utils.nvim NVIM_BIN=/path/to/nvim \
  VV_TEST_ICONS=/path/to/vv-icons.nvim ./tests/run.sh
./dev/test/selftest/run.sh
```

可选参数为匹配文件路径或中文用例名的**字面子串**，不是 pattern；无匹配返回非零
全套诊断图标场景使用统一发现的已有 `vv-icons.nvim` 源码；不同布局可用 `VV_TEST_ICONS` 覆盖。入口在启动隔离前加载 `tests/env.sh` 的依赖声明，不依赖个人配置
其它依赖：Neovim 0.12+、Git、POSIX shell、`tar`、`fd`、`mkfifo`、`ps`、`chmod`、可写 `/tmp` 与非 root 用户（真实权限失败场景）
共享入口由 `tests/env.sh` 在 HOME 隔离前查询 `rustup which cargo` 并验证/接入原生 bin；`VV_TEST_TOOLCHAIN_BIN` 可显式覆盖。非 rustup 的原生 PATH 工具仍支持
Rust 项目入口场景实际运行 `cargo metadata --no-deps`，需要可用的 Cargo 工具链，测试不构建项目或下载依赖。也可在 HOME 隔离前显式提供原生工具链 PATH，避免 shim 读取隔离 HOME 下不存在的默认工具链：

```sh
PATH="$(dirname "$(rustup which cargo)"):$PATH" CARGO_NET_OFFLINE=true ./tests/run.sh
```

其它工具链管理器同样可显式将已安装 Cargo / rustc 的原生 bin 目录加到 PATH；不需要恢复个人 HOME 或 Cargo 缓存
递归路径补全与扫描预算场景要求已有 `fd`，缺失明确失败，不能静默跳过；执行器与下载器场景注入可执行程序信号或本地 shell fixture，不运行真实下载或远程操作
mini.test commit 与缓存位置由共享 `deps.lua` 管理；离线验证须预先提供该固定版本缓存，不安装或更新依赖
设施自测另外要求 Bun；调用方 vv-replace 的完整套件需要 ripgrep

每个 case 使用全新 child Neovim。`helpers.lua` 把 cwd、HOME、四类 XDG 目录和所有 tempname 放进独立 `/tmp` fixture；路径复制使用内存剪贴板
前置 fixture 的顶层变量只共享于当前 child，`child.lua_func` 不捕获父进程 upvalue
父 `post_case` 在失败后仍按父子关系回收真实 fixture 后代进程树，再停止 child、恢复目录权限并清理文件
同步 RPC 断言直接交给 mini.test；scheduled callback 异常收集后由父 hook 断言
预期 autocmd/Ex 错误由对应场景精确判断，不无条件要求 `v:errmsg` 为空
`state_process_fixture.lua` 是并发状态写入/订阅辅助进程，不参与收集

批量删除与事务写入以 `budget_ms = 0` 和 uv idle 迭代证明真正让出事件循环，不以磁盘耗时或最大停顿判定
共享 LSP 截止使用可控时钟验证单一等待预算；缺失程序验证没有进入等待附着
`timer.throttle` 等待真实尾随事件后立刻检查新窗口，不睡过窗口再断言

所有测试 Git 写入只用于新建 `/tmp` fixture；不暂存、不提交真实仓库，不访问真实网络
同步 RPC 阻塞不能被内部 300 秒超时打断，CI 仍应设外层 job timeout 并清理整棵进程树
headless 覆盖真实 API、buffer、窗口和异步数据，不代替真实终端鼠标、视觉与完整配置手测
