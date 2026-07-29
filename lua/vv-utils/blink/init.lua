-- vv-utils 补全 descriptor 的可选 Blink source
--
-- 本模块只在宿主显式注册 `module = 'vv-utils.blink'` 时加载，不让 Blink
-- 成为 vv-utils 核心依赖

local Completion = require('vv-utils.completion')
local Items = require('vv-utils.blink.items')

local M = {}

local DEFAULTS = {
  max_items = 50,
  scan_max_items = 1000,
  timeout_ms = 250,
}

---@param opts? VVUtilsBlinkOpts
---@return VVUtilsBlinkSource
function M.new(opts)
  local source = setmetatable({}, { __index = M })
  source.opts = vim.tbl_deep_extend('force', DEFAULTS, opts or {})
  return source
end

---@param context? VVCompletionContext
---@return VVCompletionDescriptor?
local function descriptor(context)
  local buf = context and context.bufnr or vim.api.nvim_get_current_buf()
  local current = Completion.get(buf)
  if current and current.enabled and not current.enabled() then return nil end
  return current
end

---@return boolean
function M:enabled()
  return descriptor() ~= nil
end

---@return string[]
function M:get_trigger_characters()
  local current = descriptor()
  return current and current.trigger_characters or {}
end

---@param context VVCompletionContext
---@param callback fun(response: VVUtilsBlinkResponse)
---@return fun()? cancel
function M:get_completions(context, callback)
  local current = descriptor(context)
  if not current then
    callback({
      items = {},
      is_incomplete_forward = false,
      is_incomplete_backward = false,
    })
    return
  end

  local cancelled = false
  local completed = false
  ---@param result VVCompletionResult?
  local function complete(result)
    if cancelled or completed then return end
    completed = true
    callback({
      items = result and Items.convert(result, context, self.opts.max_items) or {},
      is_incomplete_forward = true,
      is_incomplete_backward = true,
    })
  end

  local value = current.complete(context, self.opts, complete)
  if type(value) == 'table' then
    complete(value)
    return
  end
  if type(value) ~= 'function' then
    complete(nil)
    return
  end

  return function()
    if cancelled then return end
    cancelled = true
    value()
  end
end

---@class VVUtilsBlinkOpts
---@field max_items? integer 最终候选上限 @default 50
---@field scan_max_items? integer 递归扫描原始结果上限 @default 1000
---@field timeout_ms? integer 递归扫描超时毫秒数 @default 250

---@class VVUtilsBlinkSource
---@field opts VVCompletionDefaults
---@field enabled fun(self: VVUtilsBlinkSource): boolean
---@field get_trigger_characters fun(self: VVUtilsBlinkSource): string[]
---@field get_completions fun(self: VVUtilsBlinkSource, context: VVCompletionContext, callback: fun(response: VVUtilsBlinkResponse)): fun()?

---@class VVUtilsBlinkResponse
---@field items lsp.CompletionItem[]
---@field is_incomplete_forward boolean
---@field is_incomplete_backward boolean

return M
