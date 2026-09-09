-- vv-utils.modal 的公共类型契约

require('vv-utils.ui_rows.types')

---@alias VVModalChunk VVUIRowsChunk

---@class VVModalRow : VVUIRowsRow
---@field icon? string
---@field icon_hl? string

---@class VVModalAction
---@field id string 唯一动作 ID
---@field label string 显示文本
---@field keys string|string[] 触发动作的键
---@field hl? string 动作高亮
---@field icon? string 可选图标；主要供上层 UI 适配器使用
---@field hint? string|false footer 使用的主键提示；缺省使用 keys 的第一个键

---@class VVModalCancel
---@field label? string @default 'Cancel'
---@field keys? string|string[] @default { 'q', '<Esc>' }
---@field hl? string @default 'Comment'
---@field icon? string
---@field hint? string|false

---@class VVModalWindowOptions
---@field border? string|string[] @default 'rounded'
---@field title_pos? 'left'|'center'|'right' @default 'center'
---@field min_width? integer @default 44
---@field max_width? integer @default min(96, editor width - 4)
---@field margin? integer @default 4
---@field zindex? integer
---@field chrome? table<string, any>

---@class VVModalOptions
---@field title string
---@field body? VVModalRow[]|VVModalRow|string|string[] 正文行
---@field render? fun(ctx: table): VVModalRow[] 正文渲染回调；与 body 二选一
---@field context? table 传给 render 的业务上下文
---@field actions VVModalAction[] 按顺序显示和绑定的动作
---@field cancel? VVModalCancel
---@field window? VVModalWindowOptions
---@field filetype? string @default 'vv-modal'
---@field on_select? fun(id: string)
---@field on_cancel? fun()

---@class VVModalHandle
---@field close fun() 关闭浮窗，不触发回调
---@field is_open fun(): boolean

return {}
