<div align="center">

# vv-utils.nvim

English | <a href="./README.zh-CN.md">中文</a>

Want my Neovim config? See <a href="https://github.com/beixiyo/dotfiles">dotfiles</a>.

<em>The shared utility library for vv-* plugins, written in pure Lua with no Lua dependencies</em>

<br />

<img src="https://img.shields.io/badge/Neovim-0.12+-57A143?style=flat-square&logo=neovim&logoColor=white" alt="Requires Neovim 0.12+" />
<img src="https://img.shields.io/badge/Lua-2C2D72?style=flat-square&logo=lua&logoColor=white" alt="Lua" />
<img src="https://img.shields.io/badge/zero_Lua_deps-✓-2ea44f?style=flat-square" alt="Zero Lua Dependencies" />

</div>

---

## Optional external tools

The core library has no Lua dependencies. Individual modules use external programs only when their corresponding feature is called:

- [Git](https://github.com/git/git) — `vv-utils.git` and Git-tracked formatting scopes
- [curl](https://github.com/curl/curl) — `vv-utils.http`
- One of [curl](https://github.com/curl/curl), [wget](https://github.com/mirror/wget), or [PowerShell](https://github.com/PowerShell/PowerShell) — `vv-utils.download`
- [tar](https://www.libarchive.org/) or `bsdtar` — `vv-utils.archive`
- A matching interpreter or runtime such as [Bun](https://github.com/oven-sh/bun), [Deno](https://github.com/denoland/deno), [Node.js](https://github.com/nodejs/node), [Python](https://github.com/python/cpython), [Ruby](https://github.com/ruby/ruby), [Perl](https://github.com/Perl/perl5), [PHP](https://github.com/php/php-src), or a shell — `vv-utils.exec`; the module selects the first available configured runner

## Installation

```lua
{
  'beixiyo/vv-utils.nvim',
  lazy = false,
  priority = 1000, -- Make it available before plugins require it during startup
}
```

## Configuration

```lua
require('vv-utils').setup({
  drop = true,
  bigfile = { size = 512 * 1024 },
  format = true,
  scroll = true,
})
```

## Modules

| Category | Modules |
|---|---|
| Foundation | [`path`](lua/vv-utils/path/README.md), [`glob`](lua/vv-utils/glob/README.md), [`yaml`](lua/vv-utils/yaml/README.md), [`timer`](lua/vv-utils/timer/README.md), [`callback`](lua/vv-utils/callback/README.md), [`color`](lua/vv-utils/color/README.md), [`hl`](lua/vv-utils/hl/README.md), [`animate`](lua/vv-utils/animate/README.md), [`transaction`](lua/vv-utils/transaction/README.md) |
| Async and completion | [`async`](lua/vv-utils/async/README.md), [`process`](lua/vv-utils/process/README.md), [`completion`](lua/vv-utils/completion/README.md), [`blink`](lua/vv-utils/blink/README.md), [`path_completion`](lua/vv-utils/path_completion/README.md), [`match`](lua/vv-utils/match/README.md) |
| Editor UI | [`tree_panel`](lua/vv-utils/tree_panel/README.md), [`prompt`](lua/vv-utils/prompt/README.md), [`input`](lua/vv-utils/input/README.md), [`keys`](lua/vv-utils/keys/README.md), [`confirm`](lua/vv-utils/confirm/README.md), [`loading`](lua/vv-utils/loading/README.md), [`ui_window`](lua/vv-utils/ui_window/README.md), [`help_panel`](lua/vv-utils/help_panel/README.md), [`keymap`](lua/vv-utils/keymap/README.md), [`mouse`](lua/vv-utils/mouse/README.md), [`scroll`](lua/vv-utils/scroll/README.md) |
| Files and state | [`fs`](lua/vv-utils/fs/README.md), [`git`](lua/vv-utils/git/README.md), [`lsp`](lua/vv-utils/lsp/README.md), [`history`](lua/vv-utils/history/README.md), [`state`](lua/vv-utils/state/README.md), [`diagnostics`](lua/vv-utils/diagnostics/README.md), [`bufdelete`](lua/vv-utils/bufdelete/README.md), [`editor`](lua/vv-utils/editor/README.md) |
| System and side effects | [`http`](lua/vv-utils/http/README.md), [`drop`](lua/vv-utils/drop/README.md), [`download`](lua/vv-utils/download/README.md), [`archive`](lua/vv-utils/archive/README.md), [`exec`](lua/vv-utils/exec/README.md), [`sys`](lua/vv-utils/sys/README.md), [`bigfile`](lua/vv-utils/bigfile/README.md), [`format`](lua/vv-utils/format/README.md) |
