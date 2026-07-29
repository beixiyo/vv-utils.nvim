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
- 与文件类型匹配的解释器或运行时，例如 [Bun](https://github.com/oven-sh/bun)、[Deno](https://github.com/denoland/deno)、[Node.js](https://github.com/nodejs/node)、[Python](https://github.com/python/cpython)、[Ruby](https://github.com/ruby/ruby)、[Perl](https://github.com/Perl/perl5)、[PHP](https://github.com/php/php-src) 或 shell — 用于 `vv-utils.exec`，模块会选择配置中第一个可执行的 runner

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
| `vv-utils.path` | `norm(p)` 规范化路径、`collapse_middle(path, opts?)` 折叠中间层级、`find_root(path, opts?)` 优先 Git 的项目根扫描、`get_root(buf?)`、`get_cwd()` |
| `vv-utils.glob` | VS Code 风格搜索 glob：按顶层逗号拆分，生成框架无关的根锚定或任意深度 pattern，并提供 ripgrep adapter |
| `vv-utils.path_completion` | 不绑定 UI 的 glob 与目录路径候选；可通过 `fd` 查询文件系统，也可复用调用方已有的相对路径索引 |
| `vv-utils.completion` | buffer-local 补全 descriptor，用于声明候选策略与生命周期 |
| `vv-utils.blink` | 可选 Blink adapter，读取当前 descriptor；默认最终返回 50 条，扫描预算 1000 条 |
| `vv-utils.yaml` | 轻量 YAML 解析（够用于 `pnpm-workspace.yaml` 等简单配置） |
| `vv-utils.fs` | fs 原语，以及提供快照校验、失败补偿回滚与单层撤回的 `new_transaction()` |
| `vv-utils.git` | 异步 git 索引：`index(root, cb)` 返回状态、忽略路径、`is_ignored` 与重命名映射；`diff_lines(path, cb, opts?)` 获取单侧行级标记，支持 `from_rev` / `to_rev` 任意 revision 范围及 `side` 新旧侧投影；`diff_line_sets(path, cb)` 同时获取 staged / unstaged 并把 staged 映射到 worktree；`symbol_for()` / `register_hl()` 提供共享装饰 |
| `vv-utils.diagnostics` | `collect_by_path()` 聚合诊断 → `{[path]={[severity]=count}}`；`symbol_for(counts)` 选最高 severity 的 `vv-icons` 图标与 `Diagnostic*` 高亮（无 `vv-icons` 时回退字母）；`format_range(buf, l1, l2?)` 行范围诊断 → `"Label: message"[]` |
| `vv-utils.lsp.workspace_edit` | 多客户端 WorkspaceEdit 规范化、去重、冲突检查、状态快照、原子应用与回滚 |
| `vv-utils.lsp.code_actions` | `collect_document_fixes(opts)` 收集安全事务；`fix_document(opts)` 直接应用整文件或指定行的可编辑修复 |
| `vv-utils.lsp.fix` | `file(opts)` / `files(paths, opts)` 等待多 LSP 修复收敛并原子应用 |
| `vv-utils.lsp.file_operations` | 收集 `workspace/willRenameFiles` 编辑并发送 `workspace/didRenameFiles`；不负责文件移动或业务事务 |
| `vv-utils.history` | 按字段隔离的输入历史：草稿恢复、去重、条数限制，以及可选的 0600 原子持久化 |
| `vv-utils.state` | `register(plugin_id, key_id)` 注册插件状态命名空间，写前合并磁盘最新数据并以 0600 原子持久化 |
| `vv-utils.timer` | `debounce(fn, wait)` / `throttle(fn, limit)`，时间参数支持传入函数实现动态延时 |
| `vv-utils.color` | 颜色解析与转换；支持 integer RGB、`#RGB[A]`、`#RRGGBB[AA]`、RGBA 对象、插值与 alpha 合成 |
| `vv-utils.hl` | 批量注册 highlight、派生低对比度版本、`ColorScheme` 后重挂与 `get_fg(name)` |
| `vv-utils.ui_window` | UI buffer 窗口 chrome 管理（关行号 / signcolumn 等），支持 restore |
| `vv-utils.help_panel` | 通用 keymap 帮助浮窗：反读 buffer mappings 按 desc 前缀分组 |
| `vv-utils.keymap` | 声明式接管 buffer-local 映射；filetype 或自定义条件失效时自动归还原映射 |
| `vv-utils.tree_panel` | 可复用的 Trouble 风格树形侧栏，支持稳定折叠、自定义区域渲染、文件预览与跳转 |
| `vv-utils.bufdelete` | 删 buffer 不破坏窗口布局：`delete` / `all` / `other` / `smart` |
| `vv-utils.loading` | buffer 行内 loading 动画：`start(opts)` → `stop()`；纯帧计时器 `ticker({on_frame})`（只跑 timer + 循环帧、每帧回调当前帧字符**不渲染**，供帧要塞进调用方自己的多段 virt_text 场景）；内置 `presets.braille`（默认）/ `dots` / `bounce`；`hl_mode='combine'` 透明背景 |
| `vv-utils.input` | 无状态受控输入装饰：给调用方持有的 buffer 行渲染 label / placeholder，支持 overlay 或虚拟行布局并返回可复用 extmark ID；不管理窗口、焦点、值或输入生命周期 |
| `vv-utils.prompt` | 底部锚定双行浮动过滤框：`open(anchor_win, opts)` → `handle{close, redraw, set_busy, set_status}`；mode badge + `<S-Tab>` 切模式、placeholder、`timer.debounce` 防抖（支持 `int\|fun` 自适应）、光标锁、失焦取消；可选 spinner（`set_busy` push 模型，帧走 `loading.ticker`）/ `on_navigate`(C-n/C-p) / `on_open_in`(C-x/C-v)。vv-flow / vv-explorer 共用 |
| `vv-utils.match` | 列表过滤命中判定（纯函数）：`compile(query, {mode, ignore_case})` → `(谓词, ok)`，编译一次复用；三模式 `fixed`（字面子串）/ `subseq`（子序列模糊）/ `regex`（vim 正则），**只判命中不打分不重排**（保住原有分组/顺序）；`next_mode` / `next_in` 模式轮换 |
| `vv-utils.editor` | `copy(text)` / `visual_range()` / `copy_path(opts?)` |
| `vv-utils.sys` | `open_default(path)` 跨平台打开（`vim.ui.open`）；niri 下额外把被打开的应用窗口聚焦回来 |
| `vv-utils.mouse` | `block_visual_drag(buf)` 给 nofile 面板挂 ModeChanged 守卫，禁止鼠标拖拽 / 多击进 visual；补 buffer-local Nop 拦不住「跨窗口点进面板再拖」的盲区 |
| `vv-utils.exec` | `resolve(path, opts?)` 按文件类型解析执行命令：shebang（`/usr/bin/env` 透传）> 扩展名运行器优先级，取首个 `executable()` 者，返回 `{cmd, runner}` 纯数据 |
| `vv-utils.download` | `file(opts, callback)` 跨平台异步下载文件；Unix 优先 `curl` / `wget`，Windows 优先 PowerShell 并显式检查 `curl.exe`，避免混淆 PowerShell 的 `curl` alias；缺少命令时返回可操作的结构化错误 |
| `vv-utils.drop` | 终端拖拽路径检测 + handler 分发（需 `setup()` 启用）。两条路统一走 `dispatch(paths, pos)`：① 覆写 `vim.paste` 从 bracketed paste 检测路径（`pos=nil`，无坐标）；② **kitty DnD 协议（OSC 72，kitty ≥ 0.47 且脱 tmux）** 带落点坐标 + 拖拽事件（`pos={x,y,op}`）。`register(handler)` 签名 `fun(paths, pos)`；`on_drag(cb)` 订阅移动/离开（实时高亮用）；内置默认 handler（Normal 下 `:edit`）；`setup({ kitty_dnd=false })` 关协议 |
| `vv-utils.bigfile` | 大文件保护（需 `setup()` 启用），禁用 matchparen / folding / completion 等 |
| `vv-utils.format` | 中英文排版：`add_spaces_around_english` / `clean_trailing`（命令需 `setup()` 启用） |
| `vv-utils.animate` | 通用补间动画引擎：`add(from, to, cb, opts?)` / `del(id)`，uv_timer 驱动 + easing（linear/outQuad/outCubic/inQuad/inOutQuad） |
| `vv-utils.scroll` | 跨窗口平滑滚动（`window(win_id, lines)` / `mouse(direction, win_id?)` / `with_view_animation(win_id, fn)` / `with_auto_suppressed(win_id, fn)`）；键盘滚动与大跳转默认平滑，鼠标默认即时，可用 `mouse='smooth'` 接管 |

## 重要说明

- `git.index(root, cb)` 返回状态、忽略路径、`is_ignored` 与 `rename_map`；图标仍由模块级 helper 提供
- `git.diff_lines(path, cb, opts?)` 返回单侧行级 diff；`opts.from_rev` / `opts.to_rev` 可选择任意 revision 范围，`opts.side` 投影到旧侧或新侧
- `git.diff_line_sets(path, cb)` 同时返回 staged / unstaged 集合，且 staged 坐标已映射到 worktree
- `loading.ticker({ on_frame })` 只调度帧并调用回调，不渲染内容
- `input.render(opts)` 装饰调用方持有的 buffer 行并返回可复用 extmark ID；不管理窗口、焦点、值或输入生命周期
- `keymap.attach(opts)` 返回含 `refresh(buf?)` / `detach()` 的 handle；仅在映射仍由它持有时才归还，因此之后的用户或插件重绑优先
- `prompt.open(anchor_win, opts)` 返回含 `close` / `redraw` / `set_busy` / `set_status` 的 handle
- `match.compile(query, { mode, ignore_case })` 编译一次，返回可复用谓词与有效状态
- `history.new({ name, max_entries?, persist?, path? })` 创建隔离实例；持久化写入会合并最新磁盘记录并原子替换，但不提供跨进程锁
- `state.register(plugin_id, key_id)` 返回由 `stdpath('state')/vv-utils/state.json` 支持的字段 handle；每次写入会重读并合并最新磁盘快照，但不提供跨进程锁
- `drop.register(handler)` 接收 `fun(paths, pos)`；`drop.on_drag(cb)` 订阅拖拽移动和离开事件
- Kitty DnD 需要 Kitty 0.47 或更高版本，且不能经由 tmux 运行

### 颜色工具

```lua
local color = require('vv-utils.color')

local rgba = color.parse('#0f08')
-- { r = 0, g = 255, b = 0, a = 136 }

color.to_hex(rgba)                              -- '#00ff0088'
color.to_integer('#00ff00')                    -- 0x00ff00
color.mix('#ff0000', '#0000ff', 0.5)           -- RGBA 对象
color.composite('#ff000080', '#0000ff')        -- source-over RGBA 对象
```

`parse()` 接受 `0xRRGGBB`、`#RGB`、`#RGBA`、`#RRGGBB`、`#RRGGBBAA` 或
`{ r, g, b, a? }`。`to_hex()` 默认输出小写，并仅在非不透明时自动包含 alpha；
可通过 `alpha = 'always'` 或 `'never'` 覆盖。`to_integer()` 遇到透明颜色时默认报错，
必须显式提供 `background` 进行合成，或设置 `discard_alpha = true`
`mix()` 对四个 RGBA 通道做插值；`composite()` 执行标准 source-over alpha 合成

## 引用方式

```lua
-- 直接引用子模块
local path = require('vv-utils.path')
path.get_root()
path.find_root('/work/repository/apps/web/src/App.tsx') -- 优先 Git 根，再回退最近 manifest
path.collapse_middle('frontend/electron/renderer/App.tsx', { head = 1, tail = 2 })

local glob = require('vv-utils.glob')
glob.compile_rg_list('*.{ts,tsx}, ./packages/core/src/')
glob.compile_list('core/src, !./vendor') -- 通用 pattern + negated 语义

local detach = require('vv-utils.completion').attach(buf, require('vv-utils.completion').path({
  mode = 'glob',
  cwd = cwd,
}))

-- Blink 宿主只需注册一次；没有 descriptor 的 buffer 会自动禁用
-- providers.vv_completion = {
--   module = 'vv-utils.blink',
--   opts = { max_items = 50, scan_max_items = 1000, timeout_ms = 250 },
-- }

-- 或走 facade
local utils = require('vv-utils')
utils.path.get_root()
utils.yaml.parse(...)

local history = require('vv-utils.history').new({
  name = 'my-plugin',
  max_entries = 50,
  persist = true,
})
history:record('search', 'needle')
history:previous('search', 'current draft')
history:next('search', 'needle')

local references_state = require('vv-utils.state').register('my-plugin', 'references')
local TreePanel = require('vv-utils.tree_panel')
local panel = TreePanel.new({
  id = 'references',
  width = 52,
  state = references_state, -- 实际宽度保存在 handle 的 `width` 字段
  on_attach = function(current, buf)
    TreePanel.apply_default_mappings(current, { q = false, x = 'close_panel' })
  end,
  source = function() return nodes end,
})
panel:toggle()
```

`tree_panel` 自身不注册快捷键。调用方通过 `on_attach(panel, buf)` 完整控制 mode、desc 和其他 keymap 选项；需要常用树操作时可调用 `apply_default_mappings(panel, overrides, opts)`，

需要显式 action/回调表时可调用 `apply_mappings`。默认映射使用 `j` / `k` / `C-n` / `C-p` 移动并预览，`h` / `l` 操作树节点，`Enter` 进入但保留侧栏，`gf` 进入并关闭侧栏，`g?` 打开帮助

渲染权属于调用方：`render.header`、`render.node`、`render.empty` 和 `render.footer` 均可返回纯文本或分段高亮 chunks。`render.winbar` 使用相同返回结构，但固定在窗口顶部，不随树节点滚动；设为 `false` 可清空。`syntax_chunks(text, lang, fallback_hl)` 可把独立源码片段转换为 Tree-sitter chunks，不修改源码 buffer 或任何编辑器全局状态

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
  -- bigfile = { size = 1024 * 500 },
})
```
