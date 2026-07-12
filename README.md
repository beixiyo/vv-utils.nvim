<h1 align="center">vv-utils.nvim</h1>

<p align="center">
  <em>vv-* 系列插件的共享工具库 — 纯 Lua，零 Lua 依赖</em>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Neovim-0.10+-57A143?style=flat-square&logo=neovim&logoColor=white" alt="Requires Neovim 0.10+" />
  <img src="https://img.shields.io/badge/Lua-2C2D72?style=flat-square&logo=lua&logoColor=white" alt="Lua" />
  <img src="https://img.shields.io/badge/zero_Lua_deps-✓-2ea44f?style=flat-square" alt="Zero Lua Dependencies" />
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
| `vv-utils.git` | 异步 git 索引：`index(root, cb)` → `{ status_map, is_ignored, symbol_for }`；`diff_lines(path, cb, opts?)` 获取单侧行级标记；`diff_line_sets(path, cb)` 同时获取 staged / unstaged 并把 staged 映射到 worktree；`register_hl()` 注册 VSCode Dark+ 调色板 |
| `vv-utils.diagnostics` | `collect_by_path()` 聚合诊断 → `{[path]={[severity]=count}}`；`symbol_for(counts)` 选最高 severity 的 `vv-icons` 图标与 `Diagnostic*` 高亮（无 `vv-icons` 时回退字母）；`format_range(buf, l1, l2?)` 行范围诊断 → `"Label: message"[]` |
| `vv-utils.timer` | `debounce(fn, wait)` / `throttle(fn, limit)`，时间参数支持传入函数实现动态延时 |
| `vv-utils.hl` | `register(augroup, specs)` 批量注册 highlight（自动 `default=true` + `ColorScheme` 重挂）；`get_fg(name)` |
| `vv-utils.ui_window` | UI buffer 窗口 chrome 管理（关行号 / signcolumn 等），支持 restore |
| `vv-utils.help_panel` | 通用 keymap 帮助浮窗：反读 buffer mappings 按 desc 前缀分组 |
| `vv-utils.bufdelete` | 删 buffer 不破坏窗口布局：`delete` / `all` / `other` / `smart` |
| `vv-utils.loading` | buffer 行内 loading 动画：`start(opts)` → `stop()`；纯帧计时器 `ticker({on_frame})`（只跑 timer + 循环帧、每帧回调当前帧字符**不渲染**，供帧要塞进调用方自己的多段 virt_text 场景）；内置 `presets.braille`（默认）/ `dots` / `bounce`；`hl_mode='combine'` 透明背景 |
| `vv-utils.prompt` | 底部锚定双行浮动过滤框：`open(anchor_win, opts)` → `handle{close, redraw, set_busy, set_status}`；mode badge + `<S-Tab>` 切模式、placeholder、`timer.debounce` 防抖（支持 `int\|fun` 自适应）、光标锁、失焦取消；可选 spinner（`set_busy` push 模型，帧走 `loading.ticker`）/ `on_navigate`(C-n/C-p) / `on_open_in`(C-x/C-v)。vv-flow / vv-explorer 共用 |
| `vv-utils.match` | 列表过滤命中判定（纯函数）：`compile(query, {mode, ignore_case})` → `(谓词, ok)`，编译一次复用；三模式 `fixed`（字面子串）/ `subseq`（子序列模糊）/ `regex`（vim 正则），**只判命中不打分不重排**（保住原有分组/顺序）；`next_mode` / `next_in` 模式轮换 |
| `vv-utils.editor` | `copy(text)` / `visual_range()` / `copy_path(opts?)` |
| `vv-utils.sys` | `open_default(path)` 跨平台打开（`vim.ui.open`）；niri 下额外把被打开的应用窗口聚焦回来 |
| `vv-utils.mouse` | `block_visual_drag(buf)` 给 nofile 面板挂 ModeChanged 守卫，禁止鼠标拖拽 / 多击进 visual；补 buffer-local Nop 拦不住「跨窗口点进面板再拖」的盲区 |
| `vv-utils.exec` | `resolve(path, opts?)` 按文件类型解析执行命令：shebang（`/usr/bin/env` 透传）> 扩展名运行器优先级，取首个 `executable()` 者，返回 `{cmd, runner}` 纯数据 |
| `vv-utils.download` | `file(opts, callback)` 跨平台异步下载文件；Unix 优先 `curl` / `wget`，Windows 优先 PowerShell 并显式检查 `curl.exe`，避免混淆 PowerShell 的 `curl` alias；缺少命令时返回可操作的结构化错误 |
| `vv-utils.drop` | 终端拖拽路径检测 + handler 分发（需 `setup()` 启用）。两条路统一走 `dispatch(paths, pos)`：① 覆写 `vim.paste` 从 bracketed paste 检测路径（`pos=nil`，无坐标）；② **kitty DnD 协议（OSC 72，kitty ≥ 0.47 且脱 tmux）** 带落点坐标 + 拖拽事件（`pos={x,y,op}`）。`register(handler)` 签名 `fun(paths, pos)`；`on_drag(cb)` 订阅移动/离开（实时高亮用）；内置默认 handler（Normal 下 `:edit`）；`setup({ kitty_dnd=false })` 关协议 |
| `vv-utils.bigfile` | 大文件保护（需 `setup()` 启用），禁用 matchparen / folding / completion 等 |
| `vv-utils.format` | 中英文排版：`add_spaces_around_english` / `clean_line_trailing`（需 `setup()` 启用） |
| `vv-utils.animate` | 通用补间动画引擎：`add(from, to, cb, opts?)` / `del(id)`，uv_timer 驱动 + easing（linear/outQuad/outCubic/inQuad/inOutQuad） |
| `vv-utils.scroll` | 跨窗口平滑滚动（`window(win_id, lines)` / `mouse(direction, win_id?)` / `with_view_animation(win_id, fn)` / `with_auto_suppressed(win_id, fn)`）；键盘滚动与大跳转默认平滑，鼠标默认即时，可用 `mouse='smooth'` 接管 |

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
  drop    = true,          -- 终端拖拽：粘贴检测 + kitty DnD 落点协议（覆写 vim.paste）
  bigfile = true,          -- 启用大文件保护
  format  = true,          -- 启用中英文排版命令（:VVAddSpaces / :VVCleanTrailing）
  scroll  = {
    duration = 180,        -- 默认动画上限（ms）
    key_duration = 120,    -- <C-e>/<C-y> 上限
    auto_duration = 108,   -- gg/G/搜索等跳转上限
    auto_max_steps = 10,   -- 自动跳转最大分步数；实际还会受 auto_duration/frame_ms 约束
    frame_ms = 12,         -- 距离较短时按帧间隔缩短动画
    mouse = 'native',      -- 鼠标默认走原生滚动；可设 'smooth'
  },
  -- 传 table 可透传子模块配置
  -- bigfile = { size_threshold = 1024 * 500 },
})
```
