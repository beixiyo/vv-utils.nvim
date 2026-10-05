# Shared vv plugin test infrastructure

English | [中文](README.zh-CN.md)

Test-only infrastructure; nothing here is loaded by the production `lua/vv-utils` API. Requires Unix-like OS, Neovim 0.12+, Git and POSIX shell. Plugin-specific external tools and integration dependencies are declared by the caller, not installed by this runner. Bun is only required for infrastructure self-tests.

## Entry points

```sh
./tests/run.sh [literal-filter]
sh /path/to/vv-utils.nvim/dev/test/run.sh /path/to/plugin.nvim [literal-filter]
VV_UTILS=/checkouts/vv-utils.nvim NVIM_BIN=/path/to/nvim ./tests/run.sh
```

Run from any cwd. Filtering matches the literal substring in `file path | case name`, not a Lua pattern. No matches, empty sets, collection errors, downloads, cases and hook failures all fail with a nonzero exit.

**Canonical consumer launcher:** copy [`launcher.sh`](launcher.sh) to the consumer's `tests/run.sh`, unchanged, and `chmod +x tests/run.sh`. It assumes `tests/` is directly inside the plugin root; only adjust the `repo=.../..` line for a different layout. It locates a checkout containing `dev/test` and delegates to the shared entry; no fetching or personal init/manager loading. Utils itself uses its own short launcher, defaulting to this repository; `VV_UTILS` can still override it.

## Discovery and overrides

A nonempty explicit source variable always wins; a bad override is a hard error with its variable/path and required marker, never fallback. Relative paths (including spaces) resolve against the original invocation cwd, before changing HOME/XDG/cwd. Selected dependency paths and their source are printed once to stderr.

For `vv_test_dependency VAR PLUGIN_NAME MARKER...`, discovery order is:

1. `VV_TEST_VENDOR_ROOT/PLUGIN_NAME` (if provided), plugin's sibling `PLUGIN_NAME`, then original Neovim config `vendors/PLUGIN_NAME`.
2. `VV_TEST_LAZY_ROOT/PLUGIN_NAME`, default original Neovim data `lazy/PLUGIN_NAME`.
3. `VV_TEST_PACK_ROOT/pack/*/start/PLUGIN_NAME`, then `pack/*/opt/PLUGIN_NAME`; default root is original data `site`. Original config pack groups are also checked last.

This includes vim.pack's official `data/site/pack/core/opt/PLUGIN_NAME`. `VV_TEST_PACK_ROOT` is a **packpath entry**, not the `pack/` directory. Roots are singular directory overrides, preserve spaces, and nonempty invalid roots fail immediately. Default roots use `${XDG_CONFIG_HOME:-$HOME/.config}/${NVIM_APPNAME:-nvim}` and `${XDG_DATA_HOME:-$HOME/.local/share}/${NVIM_APPNAME:-nvim}`. Only known roots/groups are searched; no recursive HOME scan or manager configuration is executed. A present but incomplete first candidate fails validation rather than falling through to an old installed copy. Dirty development source is used directly, never replaced by a cached vv checkout.

Custom installation directory names require explicit source variables, e.g. `VV_UTILS=/checkouts/renamed-utils` or `VV_ICONS=/checkouts/icons-dev`. For reproducible CI, check out required repositories at chosen revisions yourself and pass their source variables explicitly; fixed plugin revisions belong to CI/caller. There is no plugin downloader. A standalone consumer clone does not include utils or its integration dependencies; missing sources explain how to install/check out and override them.

## `tests/env.sh` declaration API

Sourced by the shared shell entry before isolation, with absolute `VV_TEST_REPO` and `VV_TEST_CALLER_CWD`. Declare only existing sources/runtime/toolchains. Do not install anything or run test behavior. All functions return 0 on success, nonzero with stderr diagnostics on failure:

- `vv_test_dependency VAR PLUGIN_NAME MARKER...`: find and validate existing plugin directory plus required relative entry files/directories; assign and export absolute `VAR`; no stdout. Use at least the actual module entry marker.
- `vv_test_path VAR DEFAULT_DIR MARKER...`: validate explicit `VAR` or the default directory and markers; assign/export absolute `VAR`; no stdout. Suitable for parsers and native toolchain bins.
- `vv_test_runtime VAR`: validate an already declared directory and append exactly that directory to exported `VV_TEST_RUNTIME_PATHS`; no recursive package traversal or module loading.
- Legacy `vv_test_source_path VAR DEFAULT_DIR [MARKER...]`: same path validation, **prints** the absolute directory; caller assigns/exports it. Retained for existing consumers and infrastructure regressions.

```sh
vv_test_dependency VV_ICONS vv-icons.nvim lua/vv-icons/init.lua
vv_test_dependency VV_BUFFERLINE vv-bufferline.nvim lua/vv-bufferline/init.lua
vv_test_dependency VV_TEST_SPLITS vv-splits.nvim lua/vv-splits/init.lua
vv_test_path VV_TEST_PARSERS "$VV_TEST_SITE" parser/typescript.so parser/tsx.so
vv_test_runtime VV_TEST_PARSERS
# Query files can live in an installed plugin, not just site:
vv_test_dependency VV_TEST_QUERIES nvim-treesitter queries/typescript/highlights.scm
vv_test_runtime VV_TEST_QUERIES
```

Use the caller's existing variable spelling (`VV_ICONS` / `VV_TEST_ICONS`, etc.); shared code does not guess aliases. Marker names must reflect the actual platform/files used by that suite. Preserve toolchain policy in env.sh: e.g. query `rustup which cargo` **before HOME isolation**, then `vv_test_path VV_TEST_TOOLCHAIN_BIN "$directory" cargo rustc` and prepend it to PATH. Non-rustup native executables on PATH remain supported. Utils' env.sh demonstrates this.

## Runtime, cache and isolation

`VV_TEST_SITE` defaults to original data `site`; an explicit value must be an existing directory. An absent default site is allowed when the suite does not use parsers. Parser suites must declare/validate their actual parser/query markers; missing prerequisites fail, not skip.

`VV_TEST_RUNTIME_PATHS` is an optional **newline-delimited** list of existing runtime roots, frozen to absolute paths before env.sh adds declarations. Spaces are supported; filenames containing newlines are not. The parent runner applies site (if present) and these exact roots. Each caller's child bootstrap must also run:

```lua
vim.opt.packpath = ''
dofile(vim.env.VV_UTILS .. '/dev/test/runtime.lua').apply()
-- Then prepend declared business dependency roots, utils and tested repository.
```

Do not add `site/pack` or recursively every installed package to runtimepath. Do not load personal init, lazy or vim.pack manager code. Dependencies explicitly chosen by env.sh remain the caller's responsibility to prepend in a child, including selected parser/query roots ahead of ambient site and builtin runtime.

`VV_TEST_DEPS_CACHE` defaults to `${XDG_CACHE_HOME:-$HOME/.cache}/nvim-test-deps` and is frozen before isolation. Only mini.test is automatically prepared: [`deps.lua`](deps.lua) pins its commit and atomically publishes a shared cache directory. Cache hits trust `lua/mini/test.lua`; delete a corrupted commit directory yourself. No floating branches or plugin revision resolution. Offline runs require this fixed cache already present.

`NVIM_BIN` can be a PATH command or executable path, including a relative path: it is frozen against the invocation cwd. Before any dependency preparation the shared entry clears all exported `GIT_*` variables, disables user/system Git configuration and prompts, and removes active TMUX/screen/Kitty/WezTerm/NVIM/VIM session variables. The runner then isolates HOME, TMPDIR and XDG config/data/state/cache/runtime in a scratch directory. It freezes caller TMPDIR against the invocation cwd (including relative paths) for the scratch template; normal exit and HUP/INT/TERM clean scratch. Signal exits are nonzero (129/130/143) and clean descendants owned by that invocation.

## Named tests and lifecycle

`tests/**/test_*.lua` returns a named `MiniTest.new_set()`; collection only registers cases. Windows, buffers, timers and module state should use a fresh `MiniTest.new_child_neovim()` per case. Isolate child cwd/HOME/XDG/TMPDIR **before** startup, restore parent environment even on connection failure, and clean fixture/child on failed hooks. [`tests/helpers.lua`](../../tests/helpers.lua) demonstrates this. Source paths remain frozen, never recompute sibling locations inside a child.

Use test-only [`process.lua`](process.lua) `stop_descendants(child_pid)` **before** stopping the owning child for external producers. Pass only a PID created by this case; process-tree query/cleanup failures must fail the case. Detached daemons are not covered; e.g. tmux servers need fixture-owned socket cleanup. The parent's RPC temp directory belongs to the suite, not the first case fixture.

Synchronous RPC assertion errors propagate to the parent. Scheduled callbacks need captured errors/results and finite waits; do not assume all async exceptions reach mini.test. The runner waits at most 300 seconds for event-loop completion, but this **cannot interrupt blocking synchronous RPC/infinite loops**. CI must impose an outer wall-clock/job timeout and clean the whole owned process tree and scratch after SIGKILL. Headless tests do not replace real TUI mouse/visual/keymap verification.

## Infrastructure black-box regression

```sh
NVIM_BIN=/path/to/nvim VV_TEST_DEPS_CACHE=/path/to/nvim-test-deps \
  ./dev/test/selftest/run.sh
```

Additional self-test dependencies: Bun and POSIX `ps`. Preparation can download pinned mini.test into its fixed cache; behavior fixtures copy the cache and forbid network/fetch operations. No real personal config or sibling checkout is required. Black-box cases exercise assertion/hook/collection/RPC failures; empty and unmatched literal filters; real state readback and repeated isolation; legacy declarations and relative overrides; real launchers loading distinct dirty vendors, standard/custom lazy, native start/opt/core-opt and renamed override modules; runtime/query forwarding to a real child; malicious Git/terminal environments; relative TMPDIR isolation and real write/readback; TERM cleanup; and outer timeout of genuinely blocked RPC. Each invocation has a 15-second outer deadline (blocked timeout case: 2 seconds). `KEEP=1` retains only isolated fixtures/evidence, not running processes.

Utils full suite: `./tests/run.sh`; prerequisites and behavior boundaries: [utils tests](../../tests/README.md).
