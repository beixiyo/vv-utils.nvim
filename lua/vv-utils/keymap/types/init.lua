---@alias VVKeymapRhs string|fun()

---@class VVKeymapSpec
---@field mode string|string[]
---@field lhs string
---@field rhs VVKeymapRhs
---@field opts? vim.keymap.set.Opts

---@class VVKeymapContext
---@field buf integer
---@field filetype string
---@field buftype string

---@class VVKeymapAttachOpts
---@field id string 唯一 owner ID，例如 'vv-markdown.gf'
---@field filetypes? string[] 允许生效的 filetype；省略则不按 filetype 过滤
---@field enabled? fun(): boolean 插件或功能开关；false 时恢复原映射
---@field when? fun(ctx: VVKeymapContext): boolean 额外的 buffer 级条件
---@field mappings VVKeymapSpec[]|fun(ctx: VVKeymapContext): VVKeymapSpec[]
---@field events? string|string[] 触发重新判断的 autocmd；默认 FileType

---@class VVKeymapHandle
---@field refresh fun(self: VVKeymapHandle, buf?: integer) 重新判断一个或全部已加载 buffer
---@field detach fun(self: VVKeymapHandle) 恢复仍由此 handle 持有的全部映射

---@class VVKeymapClaim
---@field previous table|nil
---@field installed table|nil
---@field mode string
---@field lhs string

---@class VVKeymapHandleState: VVKeymapHandle
---@field opts VVKeymapAttachOpts
---@field claims table<integer, table<string, VVKeymapClaim>>
---@field group integer
---@field detached boolean
