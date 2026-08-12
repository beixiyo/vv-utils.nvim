-- vv-utils.confirm 的公共类型契约

---@class VVConfirmDetail
---@field label string
---@field value string 支持换行；每个物理行都会保持详情缩进
---@field hl? string @default 'Directory'
---@field separator_before? boolean 在该详情前插入空行

---@class VVConfirmMessageLine
---@field text string
---@field hl? string @default 'Normal'
---@field icon? string 显示在该行开头的图标
---@field icon_hl? string 图标专属高亮，例如 'DiagnosticWarn'

---@class VVConfirmWindowOptions
---@field border? string|string[] @default 'rounded'
---@field title_pos? 'left'|'center'|'right' @default 'center'
---@field min_width? integer @default 44
---@field max_width? integer @default min(96, max(编辑器宽度减 4, 1))；footer 超出时拆行；过小值会按 footer 单字符宽度加内边距归一化
---@field zindex? integer

---@class VVConfirmActionConfig
---@field keys? string|string[]|false 实际触发键；false 禁用该动作的全部内置映射
---@field hint? string|false footer 展示的单个主提示；false 隐藏该动作提示

---@class VVConfirmActionsConfig
---@field confirm? VVConfirmActionConfig @default { keys = { '<C-y>' }, hint = '<C-y>' }
---@field cancel? VVConfirmActionConfig @default { keys = { 'q', '<Esc>', '<C-c>', '<CR>', 'n' }, hint = 'q' }

---@class VVConfirmConfig
---@field actions? VVConfirmActionsConfig

---@class VVConfirmOptions
---@field title string
---@field message? string|VVConfirmMessageLine|string[]|VVConfirmMessageLine[] 标题下方的说明文本
---@field details? VVConfirmDetail[] 标签和值组成的详情区
---@field confirm_label? string @default 'Confirm'
---@field confirm_icon? string @default '󰄬'
---@field confirm_hl? string 默认随 severity 变化
---@field cancel_label? string @default 'Cancel'
---@field cancel_icon? string @default '󰜺'
---@field severity? 'info'|'warn'|'danger' @default 'info'
---@field window? VVConfirmWindowOptions
---@field actions? VVConfirmActionsConfig 单次打开覆盖全局动作配置，按动作字段合并
---@field filetype? string @default 'vv-confirm'
---@field on_confirm? fun() 执行确认动作时调用
---@field on_cancel? fun() 执行取消动作时调用

---@class VVConfirmHandle
---@field close fun() 关闭浮窗，不触发回调

return {}
