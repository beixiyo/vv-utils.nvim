# vv-utils.nvim

`vv-*` 系列插件的共享工具库。纯 Lua，零外部依赖

## 安装

通常不需要手动安装——其他 `vv-*` 插件会通过 `dependencies` 自动拉取。如果你直接消费它（在自己的 keymap / 配置里 `require('vv-utils.*')`），用 lazy.nvim：

```lua
{
  'beixiyo/vv-utils.nvim',
  lazy = false,
  priority = 1000,
}
```

## 模块

| 模块 | 路径 | 作用 |
|---|---|---|
| `vv-utils.path` | [lua/vv-utils/path.lua](lua/vv-utils/path.lua) | `norm(p)` 规范化路径；`get_root(buf?)` 向上找 `.git` / `package.json` 等根标识；`get_cwd()` |
| `vv-utils.yaml` | [lua/vv-utils/yaml.lua](lua/vv-utils/yaml.lua) | 轻量 YAML 解析（够用于 pnpm-workspace.yaml 等简单配置） |
| `vv-utils.ui_window` | [lua/vv-utils/ui_window.lua](lua/vv-utils/ui_window.lua) | UI buffer 的窗口 chrome 管理（关行号 / signcolumn / cursorline 等）；支持 restore 与 BufWipeout 自动恢复 |
| `vv-utils.fs` | [lua/vv-utils/fs.lua](lua/vv-utils/fs.lua) | 底层 fs 原语：`mkdir_p` / `create_file` / `delete`（递归）/ `rename`（EXDEV 降级 copy+delete）/ `copy`（递归）/ `unique_dest` / `sync_buffers` / `exists` / `read_all` / `write_all`（原子写入） |
| `vv-utils.git` | [lua/vv-utils/git.lua](lua/vv-utils/git.lua) | 异步 git 索引：`index(root, cb, opts?)` 跑 `git status --porcelain -z --ignored`（`opts.untracked = 'all'` 展开未跟踪目录）产出 `{status_map, is_ignored(path), ignored_files, ignored_dirs, rename_map}`；`parse_porcelain_z`、`make_is_ignored`、`symbol_for(xy)` 可独立使用；`register_hl(augroup?)` 注册 VSCode Dark+ 调色板 `VVGitAdded/Modified/Deleted/Renamed/Untracked/Conflict/Ignored` |
| `vv-utils.diagnostics` | [lua/vv-utils/diagnostics.lua](lua/vv-utils/diagnostics.lua) | `collect_by_path()` 聚合所有 loaded buffer 的 `vim.diagnostic.count` → `{[abs_path]={[severity]=count}}`；`symbol_for(counts)` 选最高 severity 的 `{glyph, hl}` |
| `vv-utils.sys` | [lua/vv-utils/sys.lua](lua/vv-utils/sys.lua) | 系统集成：`open_default(path)` 使用 `vim.ui.open` 跨平台打开 |
| `vv-utils.hl` | [lua/vv-utils/hl.lua](lua/vv-utils/hl.lua) | `register(augroup, specs, opts?)` 批量注册 highlight（自动补 `default=true` + `ColorScheme` 自动重挂）；`get_fg(name, fallback?)` 读取高亮组前景色（返回 `#RRGGBB`） |
| `vv-utils.help_panel` | [lua/vv-utils/help_panel.lua](lua/vv-utils/help_panel.lua) | `open(opts)` 通用 keymap 帮助浮窗：反读 `buf` keymap（按 desc 前缀），按 action → `{cat, icon}` 分组，圆角浮窗渲染 |
| `vv-utils.bufdelete` | [lua/vv-utils/bufdelete.lua](lua/vv-utils/bufdelete.lua) | 删除 buffer 不破坏窗口布局：`delete(buf?)` / `all()` / `other()` / `smart()`（浮窗→关浮窗；分屏→关分屏；否则 delete）；`is_throwaway(buf)` / `wipe_if_throwaway(buf)` 判定并清理空 `[No Name]` |
| `vv-utils.editor` | [lua/vv-utils/editor.lua](lua/vv-utils/editor.lua) | 编辑器通用工具：`copy(text, opts?)` 写系统剪贴板 + 通知；`visual_range()` 返回可视选区行号范围；`copy_path(opts?)` 复制路径（绝对/相对项目根、可附带行号 `path:42` / 可视范围 `path:42-51`、支持外部 `path` 和 `notify=false` 静默模式） |
| `vv-utils.bigfile` | [lua/vv-utils/bigfile.lua](lua/vv-utils/bigfile.lua) | 大文件保护：需 `setup()` 启用。注册 filetype 探测（字节/行长阈值），命中后禁用 matchparen / folding / statuscolumn / conceal / completion / mini.* 系列 |
| `vv-utils.format` | [lua/vv-utils/format.lua](lua/vv-utils/format.lua) | 中英文排版（算法对齐 [vsc-word-space](https://github.com/beixiyo/vsc-word-space)）：纯函数 `add_spaces_around_english(text)` / `clean_line_trailing(text)`；buffer 副作用 `add_spaces(opts?)` / `clean_trailing(opts?)`，优先级 `opts.range = {l1, l2}` > visual 选区嗅探 > 全文；`setup({ commands = true })` 注册 `:VVAddSpaces` / `:VVCleanTrailing`（支持 range，如 `:5,10VVAddSpaces`） |

## 引用方式

直接 `require('vv-utils.path')` / `require('vv-utils.yaml')` / `require('vv-utils.ui_window')`，或者走 facade：

```lua
local utils = require('vv-utils')
utils.path.get_root()
utils.yaml.parse(...)
utils.ui_window.hide_chrome(win)
```

## 设计约定

- **无状态，无 setup**：大多数模块是纯函数库，加载即用。带副作用的模块（`bigfile` / `format`）需通过 facade 显式启用：`require('vv-utils').setup({ bigfile = true, format = true })`，缺省/`false` 不启用，传 `table` 可透传子模块配置
- **零外部依赖**：不 require 任何第三方包，仅用 `vim.api` / `vim.fn` / `vim.fs` / `vim.uv`
- **`lua/vv-utils/` 是 rtp 安装路径**：vendor 根不含 `lua` 就能被 nvim 识别

## 已知消费者

vv-* 系列共用此库，避免重复造轮子：

- [vv-explorer.nvim](https://github.com/beixiyo/vv-explorer.nvim) -- `ui_window` + `fs` + `git` + `diagnostics` + `sys` + `hl` + `help_panel`
- [vv-dashboard.nvim](https://github.com/beixiyo/vv-dashboard.nvim) -- `ui_window` + `hl`
- [vv-task-panel.nvim](https://github.com/beixiyo/vv-task-panel.nvim) -- `yaml`
- [vv-replace.nvim](https://github.com/beixiyo/vv-replace.nvim) -- `fs` + `hl` + `help_panel` + `ui_window`
- [vv-git.nvim](https://github.com/beixiyo/vv-git.nvim) -- `git` + `help_panel` + `ui_window`
- [vv-statuscol.nvim](https://github.com/beixiyo/vv-statuscol.nvim) -- `git` + `hl`
- [vv-indent.nvim](https://github.com/beixiyo/vv-indent.nvim) -- `hl`

## 与 vv-icons 的关系

`vv-utils` 不包含图标——图标拆在独立的 [vv-icons.nvim](https://github.com/beixiyo/vv-icons.nvim) 仓库（数据文件量大，且被多语言侧共同消费）。两个仓库互不依赖

## 加载顺序

如果你的其他 spec 在启动期就 `require('vv-utils.*')`（典型场景：keymap 文件直接调用 `format` / `path`），把 `vv-utils.nvim` 设为高 priority 的 eager 插件即可保证它最先 packadd：

```lua
{
  'beixiyo/vv-utils.nvim',
  lazy = false,
  priority = 1000,
}
```

否则保持懒加载，由消费方的 `dependencies = { 'beixiyo/vv-utils.nvim' }` 触发即可

## Testing

Smoke test (zero deps, runs in `-u NONE`):

```bash
nvim --headless -u NONE -l tests/test_smoke.lua
```

Expected: trailing line `X passed, 0 failed`.
