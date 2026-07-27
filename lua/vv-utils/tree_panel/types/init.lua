---@alias VVTreePanelAction
---| 'toggle_node'
---| 'open_node'
---| 'close_node'
---| 'next_item'
---| 'prev_item'
---| 'jump'
---| 'expand_all'
---| 'collapse_all'
---| 'refresh'
---| 'help'
---| 'close_panel'

---@class VVTreePanelMappingSpec
---@field action? VVTreePanelAction  与 callback 二选一
---@field callback? fun(ctx: VVTreePanelRenderContext)  与 action 二选一
---@field desc? string  g? 帮助中显示的动作名

---@alias VVTreePanelMapping VVTreePanelAction|false|fun(ctx: VVTreePanelRenderContext)|VVTreePanelMappingSpec
---@alias VVTreePanelMappings table<string, VVTreePanelMapping>

---@class VVTreePanelKeymapOptions
---@field mode? string|string[]  @default 'n'
---@field silent? boolean  @default true
---@field nowait? boolean  @default true

---@class VVTreePanelRenderContext
---@field panel VVTreePanel
---@field node? VVTreePanelNode
---@field depth? integer
---@field folded? boolean
---@field has_children? boolean
---@field count? integer

---@class VVTreePanelHelpOptions
---@field title? string
---@field title_icon? string
---@field filetype? string
---@field actions? table<string, VVHelpActionMeta>
---@field categories? string[]
---@field extra_rows? VVHelpExtraRow[]

---@class VVTreePanelRenderers
---@field winbar? false|fun(ctx: VVTreePanelRenderContext): (VVTreePanelRenderRow|string)?  固定在窗口顶部，不随 buffer 滚动；false 清空
---@field header? fun(ctx: VVTreePanelRenderContext): (VVTreePanelRenderRow|string)?
---@field node? fun(ctx: VVTreePanelRenderContext): (VVTreePanelRenderRow|string)?
---@field empty? fun(ctx: VVTreePanelRenderContext): (VVTreePanelRenderRow|string)?
---@field footer? fun(ctx: VVTreePanelRenderContext): (VVTreePanelRenderRow|string)?

---@class VVTreePanelNode
---@field id string
---@field label? string
---@field children? VVTreePanelNode[]
---@field expanded? boolean
---@field selectable? boolean
---@field location? { file: string, row: integer, col?: integer }
---@field data? any

---@class VVTreePanelRow
---@field node VVTreePanelNode
---@field depth integer
---@field parent? VVTreePanelNode
---@field is_last boolean

---@class VVTreePanelChunk
---@field [1] string
---@field [2]? string

---@class VVTreePanelRenderRow
---@field chunks? VVTreePanelChunk[]
---@field text? string
---@field hl? string
---@field virt_text? VVTreePanelChunk[]
---@field virt_text_pos? 'eol'|'eol_right_align'|'overlay'|'right_align'|'inline'  @default 'right_align'

---@class VVTreePanelSyntaxInterval
---@field start_col integer
---@field end_col integer
---@field hl string
---@field priority integer
---@field sequence integer

---@class VVTreePanelOptions
---@field id string
---@field title? string
---@field filetype? string
---@field width? integer
---@field state? VVStateHandle  宽度持久状态；使用 state 下的 `width` 字段 @default nil
---@field width_save_debounce_ms? integer  resize 后写入 state 的防抖时间 @default 120
---@field position? 'left'|'right'
---@field preview_debounce_ms? integer
---@field on_attach? fun(panel: VVTreePanel, buf: integer)  buffer 配置入口；快捷键由调用方在此注册
---@field source fun(ctx: VVTreePanelRenderContext): VVTreePanelNode[]
---@field render? VVTreePanelRenderers
---@field preview? fun(node: VVTreePanelNode, ctx: VVTreePanelRenderContext)
---@field open? fun(node: VVTreePanelNode, ctx: VVTreePanelRenderContext)  打开节点但保留 panel
---@field jump? fun(node: VVTreePanelNode, ctx: VVTreePanelRenderContext)
---@field help? false|VVTreePanelHelpOptions  `g?` 帮助面板配置；false 禁用内置帮助内容 @default nil
---@field on_refresh? fun(ctx: VVTreePanelRenderContext)
---@field close_preview? fun(ctx: VVTreePanelRenderContext)
---@field on_close? fun(ctx: VVTreePanelRenderContext)

return {}
