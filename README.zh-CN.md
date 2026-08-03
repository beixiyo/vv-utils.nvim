<div align="center">

<h1>vv-utils.nvim</h1>

<a href="./README.md">English</a> | 中文

想要我的 Neovim 配置？查看 <a href="https://github.com/beixiyo/dotfiles">dotfiles</a>

<em>vv-* 系列插件的共享工具库 — 纯 Lua，零 Lua 依赖</em>

<br />

<img src="https://img.shields.io/badge/Neovim-0.12+-57A143?style=flat-square&logo=neovim&logoColor=white" alt="Requires Neovim 0.12+" />
<img src="https://img.shields.io/badge/Lua-2C2D72?style=flat-square&logo=lua&logoColor=white" alt="Lua" />
<img src="https://img.shields.io/badge/zero_Lua_deps-✓-2ea44f?style=flat-square" alt="Zero Lua Dependencies" />
</div>

---

## 可选外部工具

核心库没有 Lua 依赖；只有调用对应模块时才需要外部程序：

- [Git](https://github.com/git/git) — 用于 `vv-utils.git` 和按 Git tracked 文件执行的格式化范围
- [curl](https://github.com/curl/curl)、[wget](https://github.com/mirror/wget) 或 [PowerShell](https://github.com/PowerShell/PowerShell) 中任意一个 — 用于 `vv-utils.download`
- 与文件类型匹配的解释器或运行时，例如 [Bun](https://github.com/oven-sh/bun)、[Deno](https://github.com/denoland/deno)、[Node.js](https://github.com/nodejs/node)、[Python](https://github.com/python/cpython)、[Ruby](https://github.com/ruby/ruby)、[Perl](https://github.com/perl/perl5)、[PHP](https://github.com/php/php-src) 或 shell — 用于 `vv-utils.exec`

## 安装

```lua
{
  'beixiyo/vv-utils.nvim',
  lazy = false,
  priority = 1000,
}
```

## 配置

```lua
require('vv-utils').setup({
  drop = true,
  bigfile = { size = 512 * 1024 },
  format = true,
  scroll = true,
})
```

## 模块

| 分类 | 模块 |
|---|---|
| 基础 | [`path`](lua/vv-utils/path/README.md)、[`glob`](lua/vv-utils/glob/README.md)、[`yaml`](lua/vv-utils/yaml/README.md)、[`timer`](lua/vv-utils/timer/README.md)、[`color`](lua/vv-utils/color/README.md)、[`hl`](lua/vv-utils/hl/README.md)、[`animate`](lua/vv-utils/animate/README.md) |
| 异步与补全 | [`async`](lua/vv-utils/async/README.md)、[`completion`](lua/vv-utils/completion/README.md)、[`blink`](lua/vv-utils/blink/README.md)、[`path_completion`](lua/vv-utils/path_completion/README.md)、[`match`](lua/vv-utils/match/README.md) |
| 编辑器 UI | [`tree_panel`](lua/vv-utils/tree_panel/README.md)、[`prompt`](lua/vv-utils/prompt/README.md)、[`input`](lua/vv-utils/input/README.md)、[`loading`](lua/vv-utils/loading/README.md)、[`ui_window`](lua/vv-utils/ui_window/README.md)、[`help_panel`](lua/vv-utils/help_panel/README.md)、[`keymap`](lua/vv-utils/keymap/README.md)、[`mouse`](lua/vv-utils/mouse/README.md)、[`scroll`](lua/vv-utils/scroll/README.md) |
| 文件与状态 | [`fs`](lua/vv-utils/fs/README.md)、[`git`](lua/vv-utils/git/README.md)、[`lsp`](lua/vv-utils/lsp/README.md)、[`history`](lua/vv-utils/history/README.md)、[`state`](lua/vv-utils/state/README.md)、[`diagnostics`](lua/vv-utils/diagnostics/README.md)、[`bufdelete`](lua/vv-utils/bufdelete/README.md)、[`editor`](lua/vv-utils/editor/README.md) |
| 系统与副作用 | [`drop`](lua/vv-utils/drop/README.md)、[`download`](lua/vv-utils/download/README.md)、[`exec`](lua/vv-utils/exec/README.md)、[`sys`](lua/vv-utils/sys/README.md)、[`bigfile`](lua/vv-utils/bigfile/README.md)、[`format`](lua/vv-utils/format/README.md) |
