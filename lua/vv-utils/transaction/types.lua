-- 通用事务公共类型

---@alias vv-utils.transaction.Phase 'apply'|'undo'|'undo-recover'
---@alias vv-utils.transaction.OperationCallback fun(ok: boolean, value_or_error?: any)
---@alias vv-utils.transaction.OperationMethod fun(context: any, callback: vv-utils.transaction.OperationCallback, result?: any, phase?: vv-utils.transaction.Phase)

---@class vv-utils.transaction.Operation
---@field name? string 操作名称，用于错误信息 @default "operation #n"
---@field validate? vv-utils.transaction.OperationMethod
---@field apply? vv-utils.transaction.OperationMethod
---@field rollback? vv-utils.transaction.OperationMethod
---@field compensate? vv-utils.transaction.OperationMethod
---@field async? boolean 显式声明 operation 必须通过 callback 完成 @default false
---@field callback? boolean 等价于 `async = true` @default false
---@field callback_style? 'boolean'|'node' @default 'boolean'

---@class vv-utils.transaction.Failure
---@field error any
---@field touched boolean

---@class vv-utils.transaction.Options
---@field operations? vv-utils.transaction.Operation[] @default {}

---@class vv-utils.transaction.Result
---@field phase 'apply'|'undo'
---@field touched integer
---@field count integer
---@field undoable boolean
---@field values any[]

---@class vv-utils.transaction.Transaction
---@field operations vv-utils.transaction.Operation[]
---@field busy boolean
---@field locked boolean
---@field inconsistent boolean
---@field last table?

return {}
