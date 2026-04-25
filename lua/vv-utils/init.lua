-- vv-utils facade
-- 子模块：
--   path        路径工具
--   yaml        轻量解析
--   ui_window   UI buffer 的窗口 chrome 管理
--   fs          fs 原语（mkdir_p / create_file / delete / rename / copy / unique_dest / sync_buffers）
--   git         git status 索引 + porcelain 解析 + ignored 命中判断（异步）
--   diagnostics 按路径聚合所有 loaded buffer 的 LSP 诊断计数
--   sys         系统集成（open_default 跨平台）
--   hl          批量注册 highlight（default=true + ColorScheme 自动重挂）
--   help_panel  通用 keymap 帮助浮窗（反读 buffer keymap 按分类渲染）
--   bufdelete   删除 buffer 不破坏窗口布局
--   editor      编辑器通用工具（剪贴板 copy / 可视选区 visual_range）
--   bigfile     【副作用】大文件保护：filetype 探测 + 禁用重开销特性
--   format      【副作用可选】中英文加空格 / 行尾清理（开启时注册 :VVAddSpaces / :VVCleanTrailing）
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
---@field bigfile? boolean|vv-utils.bigfile.Opts  true=默认启用；table=启用并透传；缺省/false=不启用
---@field format?  boolean|vv-utils.format.Opts   true=默认启用；table=启用并透传；缺省/false=不启用

local M = {}

-- 列出所有「带可选 setup 副作用」的子模块；新增带副作用的模块只需在此追加
local SETUPABLE = { 'bigfile', 'format' }

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
