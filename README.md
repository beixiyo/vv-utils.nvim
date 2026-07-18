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
- One of [curl](https://github.com/curl/curl), [wget](https://github.com/mirror/wget), or [PowerShell](https://github.com/PowerShell/PowerShell) — `vv-utils.download`
- A matching interpreter or runtime such as [Bun](https://github.com/oven-sh/bun), [Deno](https://github.com/denoland/deno), [Node.js](https://github.com/nodejs/node), [Python](https://github.com/python/cpython), [Ruby](https://github.com/ruby/ruby), [Perl](https://github.com/Perl/perl5), [PHP](https://github.com/php/php-src), or a shell — `vv-utils.exec`; the module selects the first available configured runner

## Installation

Manual installation is usually unnecessary because other `vv-*` plugins pull it in through `dependencies`. To consume it directly:

```lua
{
  'beixiyo/vv-utils.nvim',
  lazy = false,
  priority = 1000, -- Make it available before plugins require it during startup
}
```

## Modules

| Module | Description |
|---|---|
| `vv-utils.path` | Path normalization, middle-segment collapsing, project-root discovery, and current-directory lookup |
| `vv-utils.yaml` | Lightweight YAML parsing for simple files such as `pnpm-workspace.yaml` |
| `vv-utils.fs` | Filesystem primitives: recursive create/delete/copy, EXDEV-safe rename, full reads, and atomic writes |
| `vv-utils.git` | Async Git indexing, single-side line diffs, mapped staged/unstaged line sets, symbols, and shared highlights |
| `vv-utils.diagnostics` | Diagnostics grouped by path, highest-severity symbols, and formatted diagnostics for line ranges |
| `vv-utils.lsp.workspace_edit` | Multi-client WorkspaceEdit normalization, deduplication, conflict checks, snapshots, atomic apply, and rollback |
| `vv-utils.lsp.code_actions` | Collect safe document-fix transactions or apply editable fixes to a document or line range |
| `vv-utils.lsp.fix` | Apply converged multi-LSP fixes atomically to one file or multiple paths |
| `vv-utils.lsp.file_operations` | Collect `workspace/willRenameFiles` edits and send `workspace/didRenameFiles`; it does not move files |
| `vv-utils.timer` | Debounce and throttle helpers with fixed or dynamically calculated delays |
| `vv-utils.hl` | Batch highlight registration with `default=true`, ColorScheme refresh, and foreground lookup |
| `vv-utils.ui_window` | Hide and restore UI-buffer window chrome such as line numbers and sign columns |
| `vv-utils.help_panel` | Shared keymap help panel generated from buffer mappings grouped by description prefixes |
| `vv-utils.bufdelete` | Layout-safe buffer deletion through `delete`, `all`, `other`, and `smart` |
| `vv-utils.loading` | Inline loading animation plus a render-free frame ticker and braille, dots, and bounce presets |
| `vv-utils.prompt` | Bottom-anchored two-line filtering prompt with modes, debounce, spinner, navigation, and split-open callbacks |
| `vv-utils.match` | Compile fixed, subsequence, or Vim-regex predicates without scoring or reordering the source list |
| `vv-utils.editor` | Text copy, Visual range, and path-copy helpers |
| `vv-utils.sys` | Cross-platform default-app opening through `vim.ui.open`, with niri focus restoration |
| `vv-utils.mouse` | Prevent nofile panels from entering Visual mode through mouse drags or multi-clicks, including cross-window drags |
| `vv-utils.exec` | Resolve commands from shebangs or extension-specific executable runners and return pure `{ cmd, runner }` data |
| `vv-utils.download` | Async cross-platform downloads via curl, wget, or PowerShell with structured actionable errors |
| `vv-utils.drop` | Terminal path-drop dispatch through bracketed paste and optional Kitty OSC 72 coordinates and drag events |
| `vv-utils.bigfile` | Opt-in large-file protection that disables expensive editor features |
| `vv-utils.format` | Opt-in Chinese/English spacing and trailing-whitespace cleanup commands |
| `vv-utils.animate` | Timer-driven interpolation with linear, quadratic, and cubic easing functions |
| `vv-utils.scroll` | Cross-window smooth scrolling, view animations, auto-animation suppression, and native or smooth mouse behavior |

Important details:

- `git.index(root, cb)` returns `status_map`, `is_ignored`, and symbol helpers
- `git.diff_lines(path, cb, opts?)` returns one side of a line diff; `git.diff_line_sets(path, cb)` returns staged and unstaged sets with staged coordinates mapped to the worktree
- `loading.ticker({ on_frame })` only schedules frames and invokes the callback; it does not render them
- `prompt.open(anchor_win, opts)` returns a handle with `close`, `redraw`, `set_busy`, and `set_status`
- `match.compile(query, { mode, ignore_case })` compiles once and returns a reusable predicate plus validity status
- `drop.register(handler)` receives `fun(paths, pos)`, while `drop.on_drag(cb)` subscribes to movement and leave events
- Kitty DnD requires Kitty 0.47 or newer and does not operate through tmux

## Imports

```lua
local path = require('vv-utils.path')
path.get_root()
path.collapse_middle('frontend/electron/renderer/App.tsx', { head = 1, tail = 2 })

local utils = require('vv-utils')
utils.path.get_root()
utils.yaml.parse(...)
```

## Configuration

Most modules are pure-function libraries and need no setup. Modules with side effects must be enabled explicitly:

```lua
require('vv-utils').setup({
  drop = true,          -- Paste detection and Kitty DnD coordinates; overrides vim.paste
  bigfile = true,       -- Enable large-file protection
  format = true,        -- Enable :VVAddSpaces and :VVCleanTrailing
  scroll = {
    duration = 180,     -- General animation cap in milliseconds
    key_duration = 120, -- <C-e>/<C-y> animation cap
    auto_duration = 108,-- gg/G/search jump animation cap
    auto_max_steps = 10,-- Also bounded by auto_duration/frame_ms
    frame_ms = 12,      -- Shorten short-distance animation by frame interval
    mouse = 'native',   -- Set to 'smooth' to intercept mouse scrolling
  },
  -- Tables are forwarded to their modules:
  -- bigfile = { size = 1024 * 500 },
})
```
