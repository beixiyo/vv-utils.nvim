-- vv-utils facade
-- 子模块：
--   path        路径工具
--   glob        VS Code 风格搜索 glob 拆分与 ripgrep pattern 编译
--   path_completion 基于 cwd 的 glob / 目录路径候选（不绑定具体输入 UI）
--   completion  buffer-local 补全 descriptor 生命周期与候选策略
--   blink       【可选集成】统一 descriptor 到 Blink CompletionItem 的 source
--   yaml        轻量解析
--   ui_window   UI buffer 的窗口 chrome 管理
--   fs          fs 原语 + 多文件完整内容事务（new_transaction）
--   git         git status 索引 + porcelain 解析 + ignored 命中判断（异步）
--   diagnostics 按路径聚合所有 loaded buffer 的 LSP 诊断计数
--   lsp         LSP Code Action、WorkspaceEdit 与文件操作协议原语
--   history     按字段隔离的输入历史（草稿恢复 + 可选 0600 原子持久化）
--   state       按插件与功能 ID 隔离的通用 JSON 持久状态
--   async       与业务无关的异步 request scope（逻辑失效 + 调用方资源清理协调）
--   callback    回调执行次数限制与失效控制
--   process     异步子进程启动、取消与主循环投递
--   http        安全的非流式 HTTP 请求与 query component 编码
--   sys         系统集成（open_default 跨平台 + niri 焦点跟随）
--   mouse       nofile 面板鼠标防护（block_visual_drag：禁拖拽/多击含跨窗口拖入进 visual）
--   exec        按文件类型解析执行命令（shebang / 扩展名优先级，纯函数）
--   download    跨平台文件下载（curl / wget / PowerShell 自动选择）
--   archive     跨平台 tar 归档读取与安全解压（tar / bsdtar 自动选择）
--   match       列表过滤命中判定（fixed / subseq / regex，compile 一次复用，纯函数）
--   input       声明式输入字段装饰（label / placeholder extmark + key/action 标签）
--   keys        Neovim 键位记号的紧凑展示（^ / ⌥ / ⇧ / ⌘ / ↵）
--   confirm     通用确认浮窗（可配置内容、动作、危险级别与窗口参数）
--   prompt      底部锚定双行浮动输入框（filter prompt：mode badge / spinner / 防抖 / close 句柄）
--   color       RGB / RGBA 解析、格式化、插值与 alpha 合成
--   hl          批量注册 highlight（default=true + ColorScheme 自动重挂）
--   help_panel  通用 keymap 帮助浮窗（反读 buffer keymap 按分类渲染）
--   keymap      buffer-local 映射的声明式接管与恢复（按 filetype / 条件自动同步）
--   bufdelete   删除 buffer 不破坏窗口布局
--   loading     通用 buffer 行内 loading 动画（spinner / dots / bounce，start(opts)→stop）
--   editor      编辑器通用工具（剪贴板 copy / 可视选区 visual_range）
--   drop        【副作用】终端拖拽路径检测 + handler 分发（覆写 vim.paste）
--   bigfile     【副作用】大文件保护：filetype 探测 + 禁用重开销特性
--   format      【副作用可选】中英文加空格 / 行尾清理（开启时注册 :VVAddSpaces / :VVCleanTrailing）
--   scroll      跨窗口平滑滚动（基于 vv-utils.animate，支持 easing + 连按去重 / 跳转动画包装）
--   transaction 通用事务机制（顺序预检、失败逆序补偿、锁定与一层撤回）
--
-- 用法：
--   local vv = require('vv-utils')
--
--   -- 一次启用全部带副作用的模块（默认配置）
--   vv.setup({ bigfile = true, format = true })
--
--   -- 启用并自定义某模块配置
--   vv.setup({
--     bigfile = { size = 3 * 1024 * 1024 },
--     format  = { commands = false },     -- 禁用 user command 注册
--   })
--
--   -- 不调 setup（或传空表）→ 任何带副作用模块都不会启动
--   vv.setup()
--
--   -- 纯函数子模块永远可懒访问，不依赖 setup
--   vv.path.get_root()
--   vv.format.add_spaces_around_english('你好world')

---@class vv-utils.Opts
---@field drop?    boolean|vv-utils.drop.Opts      true=安装 vim.paste 拦截；缺省/false=不启用
---@field bigfile? boolean|vv-utils.bigfile.Opts   true=默认启用；table=启用并透传；缺省/false=不启用
---@field format?  boolean|vv-utils.format.Opts    true=默认启用；table=启用并透传；缺省/false=不启用
---@field scroll?  boolean|vv-utils.scroll.Opts    true=键盘滚动和视口跳转动画；table=启用并透传配置；缺省/false=不启用
---@field confirm? boolean|VVConfirmConfig         true=使用默认动作；table=配置全局确认框动作；缺省/false=保持模块默认值

local M = {}

-- 列出所有可由 facade 统一配置的子模块；未显式传入的模块保持当前配置
local SETUPABLE = {
  'drop',
  'bigfile',
  'format',
  'scroll',
  'confirm',
}

---@param opts? vv-utils.Opts
function M.setup(opts)
  opts = opts or {}

  for _, name in ipairs(SETUPABLE) do
    local cfg = opts[name]
    if cfg then
      local mod_opts = type(cfg) == 'table' and cfg or nil
      require('vv-utils.' .. name).setup(mod_opts)
    end
  end
end

return setmetatable(M, {
  __index = function(_, key)
    local mod = require('vv-utils.' .. key)
    rawset(M, key, mod)
    return mod
  end,
})
