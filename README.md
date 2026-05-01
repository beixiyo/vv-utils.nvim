<h1 align="center">vv-utils.nvim</h1>

<p align="center">
  <em>vv-* 系列插件的共享工具库 — 纯 Lua，零外部依赖</em>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Neovim-0.10+-57A143?style=flat-square&logo=neovim&logoColor=white" alt="Requires Neovim 0.10+" />
  <img src="https://img.shields.io/badge/Lua-2C2D72?style=flat-square&logo=lua&logoColor=white" alt="Lua" />
  <img src="https://img.shields.io/badge/zero_deps-✓-2ea44f?style=flat-square" alt="Zero Dependencies" />
</p>

---

## 安装

通常不需要手动安装 — 其他 `vv-*` 插件通过 `dependencies` 自动拉取。如果直接消费：

```lua
{
  'beixiyo/vv-utils.nvim',
  lazy = false,
  priority = 1000, -- 其他插件启动期 require 时需要先就位
}
```

## 模块

| 模块 | 说明 |
|------|------|
| `vv-utils.path` | `norm(p)` 规范化路径、`get_root(buf?)` 向上找项目根、`get_cwd()` |
| `vv-utils.yaml` | 轻量 YAML 解析（够用于 `pnpm-workspace.yaml` 等简单配置） |
| `vv-utils.fs` | fs 原语：`mkdir_p` / `create_file` / `delete`（递归）/ `rename`（EXDEV 降级）/ `copy`（递归）/ `read_all` / `write_all`（原子写入） |
| `vv-utils.git` | 异步 git 索引：`index(root, cb)` → `{ status_map, is_ignored, symbol_for }`；`register_hl()` 注册 VSCode Dark+ 调色板 |
| `vv-utils.diagnostics` | `collect_by_path()` 聚合诊断 → `{[path]={[severity]=count}}`；`symbol_for(counts)` 选最高 severity |
| `vv-utils.hl` | `register(augroup, specs)` 批量注册 highlight（自动 `default=true` + `ColorScheme` 重挂）；`get_fg(name)` |
| `vv-utils.ui_window` | UI buffer 窗口 chrome 管理（关行号 / signcolumn 等），支持 restore |
| `vv-utils.help_panel` | 通用 keymap 帮助浮窗：反读 buffer mappings 按 desc 前缀分组 |
| `vv-utils.bufdelete` | 删 buffer 不破坏窗口布局：`delete` / `all` / `other` / `smart` |
| `vv-utils.editor` | `copy(text)` / `visual_range()` / `copy_path(opts?)` |
| `vv-utils.sys` | `open_default(path)` 跨平台打开（`vim.ui.open`） |
| `vv-utils.bigfile` | 大文件保护（需 `setup()` 启用），禁用 matchparen / folding / completion 等 |
| `vv-utils.format` | 中英文排版：`add_spaces_around_english` / `clean_line_trailing`（需 `setup()` 启用） |

## 引用方式

```lua
-- 直接引用子模块
local path = require('vv-utils.path')
path.get_root()

-- 或走 facade
local utils = require('vv-utils')
utils.path.get_root()
utils.yaml.parse(...)
```

## 配置

大多数模块是纯函数库，无需配置。带副作用的模块需显式启用：

```lua
require('vv-utils').setup({
  bigfile = true,          -- 启用大文件保护
  format = true,           -- 启用中英文排版命令（:VVAddSpaces / :VVCleanTrailing）
  -- 传 table 可透传子模块配置
  -- bigfile = { size_threshold = 1024 * 500 },
})
```
