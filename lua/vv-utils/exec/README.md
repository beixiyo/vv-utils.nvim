# `vv-utils.exec`

## 职责

仅解析“一个文件或项目入口应该如何执行”，不启动进程。上层 UI、终端或任务系统可复用同一套选择规则

```lua
local resolved = require('vv-utils.exec').resolve('/work/script.ts')
if resolved then vim.system(resolved.cmd, { cwd = resolved.cwd }) end
```

`resolve(path, opts?)` 成功返回 `VVExecPlan`（`{ cmd, runner, cwd?, target? }`）；失败返回 `nil, err`。`cmd` 始终是未经过 shell 拼接的 argv。内置项目解析器会将 `target` 设为 `project`，单文件 runner/shebang 会设为 `file`

`cwd` 只在项目入口或自定义项目解析器明确提供时出现。模块不会切换 Neovim 的工作目录；调用方应将它作为进程的执行目录传给自己的启动 API。自定义计划可用 `target = 'file' | 'project'` 向 UI 声明展示语义。含路径的相对 runner（例如 `./scripts/run`）会在检查可执行性时相对源文件目录解析，并以绝对路径写回 `cmd[1]`，因此换 cwd 启动也不会失效

## 子模块入口

所有子模块都通过 `require('vv-utils.exec')` 暴露，调用方不需要依赖内部文件路径：

- `exec.confirm`：默认执行确认浮窗
- `exec.source`：可配置注释语法的源码前导 token 读取器
- `exec.common`：argv 组合、runner 可执行性与项目根查找基元
- `exec.parsers`：内置项目入口解析器注册表
- `exec.runners`：默认单文件 runner 优先级表

## 解析顺序

1. shebang：包括 `/usr/bin/env` 与 `env -S`
2. 项目入口：由对应语言解析器决定命令和项目 cwd
3. 单文件 runner：按扩展名选第一个已安装的解释器

项目入口通常返回 `cwd`，调用方应优先使用它。单文件 runner 默认不返回 `cwd`；如果 runner 本身是相对路径，`cmd[1]` 已经是相对源文件目录归一化后的绝对路径

## 项目入口

### Rust

需要文件位于含 `Cargo.toml` 的项目中

- `src/main.rs`

  ```sh
  cargo run
  ```

- `src/bin/<name>.rs`、`src/bin/<name>/main.rs` 或 manifest 中声明的 `[[bin]] path`

  ```sh
  cargo run --bin <name>
  ```

- `examples/<name>.rs` 或 manifest 中声明的 `[[example]] path`

  ```sh
  cargo run --example <name>
  ```

解析器同步调用 `cargo metadata --no-deps --format-version 1`，按 Cargo 返回的 `src_path` 精确选择当前 target，并始终传递 `--bin` 或 `--example`，因此不受多 binary 和 `default-run` 歧义影响。target 的 `required-features` 会作为 `--features` 传递，virtual workspace 使用目标所属成员 package 的 cwd；缺失文件、非运行 target 或 metadata 失败时回退到普通 runner

### Go

- module 内的 `package main`：`go run .`，运行整个 package
- 无 `go.mod` 的 `package main` 单文件：`go run <file>`

Go 只检查源文件首个非注释 token 是否声明 `package main`。`func main()`、GOOS/GOARCH、build tags、cgo 和同 package 文件选择均由实际执行的 `go run` 处理，不在 Lua 中重复实现 Go 构建规则

## 单文件 runner

- Shell：`.sh`、`.bash`、`.zsh`、`.fish`
- JavaScript / TypeScript：`.js`、`.mjs`、`.cjs`、`.ts`、`.tsx`、`.mts`、`.cts`
- Python / Lua：`.py`、`.lua`
- Swift / Dart / Zig / Julia：`.swift`、`.dart`、`.zig`、`.jl`
- Java 11+：`.java`（单文件模式：`java <file>`）
- Ruby / Perl / PHP：`.rb`、`.pl`、`.php`

每种扩展名按配置中的优先级选择第一个已安装的 runner。任意文件若带可用 shebang，则 shebang 优先

Java 的 Maven / Gradle 项目不在此模块推断 classpath、构建任务或主类；请从项目自己的任务运行

## 自定义

```lua
require('vv-utils.exec').resolve(path, {
  shebang = false,
  project_runners = {
    rs = false,
    foo = function(file)
      return { cmd = { 'custom-run', file }, runner = 'custom' }
    end,
  },
  runners = {
    foo = { { 'foo-run' } },
  },
})
```

`project_runners.<ext> = false` 会禁用该扩展名的内置项目解析器，然后继续普通扩展名 runner。自定义解析器返回 `nil` 时也会走同一回退；返回的 `cwd` 是可选字段

## 边界

返回值是纯 argv 数据与可选项目 cwd，不包含 shell 拼接、环境变量、终端展示或错误通知；这些属于调用方执行策略
