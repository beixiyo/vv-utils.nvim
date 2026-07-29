-- 补全上下文注册与通用候选生成
--
-- 插件把补全策略挂到自己持有的 buffer；具体补全框架只读取当前 buffer 的
-- descriptor，不需要知道 vv-replace、vv-explorer 等业务模块

local PathCompletion = require('vv-utils.path_completion')

local M = {}

---@type table<integer, {descriptor: VVCompletionDescriptor, token: integer}>
local descriptors = {}

---@type table<integer, boolean>
local watched_buffers = {}

local next_token = 0

---@param value string|fun(): string
---@return string
local function resolve_string(value)
  if type(value) == 'string' then return value end
  local resolve = value
  ---@cast resolve fun(): string
  local resolved = resolve()
  return resolved
end

---@param buf integer
local function ensure_watcher(buf)
  if watched_buffers[buf] then return end
  watched_buffers[buf] = true

  vim.api.nvim_buf_attach(buf, false, {
    on_detach = function()
      descriptors[buf] = nil
      watched_buffers[buf] = nil
    end,
  })
end

---给 buffer 绑定补全策略，返回幂等 detach
---@param buf integer
---@param descriptor VVCompletionDescriptor
---@return fun()
function M.attach(buf, descriptor)
  assert(vim.api.nvim_buf_is_valid(buf), 'vv-utils.completion: invalid buffer')
  assert(type(descriptor) == 'table' and type(descriptor.complete) == 'function',
    'vv-utils.completion: descriptor.complete must be a function')

  next_token = next_token + 1
  local token = next_token
  descriptors[buf] = { descriptor = descriptor, token = token }
  ensure_watcher(buf)
  local detached = false

  return function()
    if detached then return end
    detached = true
    local current = descriptors[buf]
    if current and current.token == token then descriptors[buf] = nil end
  end
end

---@param buf integer
---@return VVCompletionDescriptor?
function M.get(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    descriptors[buf] = nil
    return nil
  end
  local current = descriptors[buf]
  return current and current.descriptor or nil
end

---@param buf integer
function M.detach(buf)
  descriptors[buf] = nil
end

---创建 glob 或纯目录路径补全 descriptor
---@param opts VVPathCompletionDescriptorOpts
---@return VVCompletionDescriptor
function M.path(opts)
  assert(opts and (opts.mode == 'glob' or opts.mode == 'directory'),
    "vv-utils.completion.path: mode must be 'glob' or 'directory'")

  return {
    trigger_characters = { '/', '.', ',', '!', '\\' },
    complete = function(context, defaults, callback)
      local max_items = opts.max_items or defaults.max_items
      local path_opts = {
        cwd = resolve_string(opts.cwd),
        cursor = context.cursor[2],
        max_items = max_items,
        scan_max_items = opts.scan_max_items or defaults.scan_max_items,
        timeout_ms = opts.timeout_ms or defaults.timeout_ms,
      }

      if callback then
        if opts.mode == 'glob' then
          return PathCompletion.glob_async(context.line, path_opts, callback)
        end
        return PathCompletion.directory_async(context.line, path_opts, callback)
      end

      if opts.mode == 'glob' then return PathCompletion.glob(context.line, path_opts) end
      return PathCompletion.directory(context.line, path_opts)
    end,
  }
end

---@class VVCompletionDescriptor
---@field enabled? fun(): boolean 当前 buffer 内是否处于可补全输入
---@field complete fun(context: VVCompletionContext, defaults: VVCompletionDefaults, callback?: fun(result: VVCompletionResult?)): VVCompletionResult|fun()|nil 同步返回结果，或异步回调并返回幂等 cancel
---@field trigger_characters? string[] 非字母数字触发字符

---@class VVCompletionResult
---@field start_col integer 需要替换的 0-based byte 起始列
---@field items VVCompletionItem[] 补全候选
---@field pre_filtered? boolean 候选已由调用方过滤和排序，adapter 不应再次改变顺序 @default false

---@class VVCompletionItem
---@field word string 接受候选时插入的文本
---@field abbr? string 菜单显示文本 @default word
---@field kind? 'File'|'Folder' 候选类型 @default File
---@field rank? integer 调用方已计算的稳定排名，数值越小越优先

---@class VVCompletionContext
---@field bufnr integer
---@field line string
---@field cursor [integer, integer] 1-based row 与 0-based byte column
---@field bounds? {start_col: integer, length: integer} Blink 当前 keyword 范围；start_col 为 1-based byte column

---@class VVCompletionDefaults
---@field max_items integer 最终返回给补全框架的候选上限
---@field scan_max_items integer 递归扫描的原始结果上限
---@field timeout_ms integer 递归扫描超时毫秒数

---@class VVPathCompletionDescriptorOpts
---@field mode 'glob'|'directory'
---@field cwd string|fun(): string
---@field max_items? integer 最终候选上限 @default source config
---@field scan_max_items? integer 递归扫描原始结果上限 @default source config
---@field timeout_ms? integer 递归扫描超时毫秒数 @default source config

return M
