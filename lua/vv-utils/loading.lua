-- vv-utils.loading — 通用 buffer 行内 loading 动画
--
-- 在 buffer 指定行以 virt_text 渲染滚动帧动画，返回 stop 函数。
-- 每次 start() 创建独立 namespace，多个实例互不干扰。
--
-- 用法：
--   local stop = require('vv-utils.loading').start({
--     buf     = state.buf,
--     get_row = function() return state.path_to_row and state.path_to_row[path] end,
--   })
--   -- ... 异步操作完成后：
--   stop()
--
-- 扩展新效果：向 M.presets 追加帧列表，或直接传 opts.frames。

local M = {}

---@type table<string, string[]>
M.presets = {
  braille = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' },
  dots    = { '⣾', '⣽', '⣻', '⢿', '⡿', '⣟', '⣯', '⣷' },
  bounce  = { '▏', '▎', '▍', '▌', '▋', '▊', '▉', '▊', '▋', '▌', '▍', '▎' },
}

local ns_counter = 0

---@class VVLoadingOpts
---@field buf integer           目标 buffer
---@field get_row fun():integer?  返回 1-based 行号；nil 则跳过本帧
---@field frames? string[]      动画帧列表，默认 braille preset
---@field interval_ms? integer  每帧间隔毫秒 @default 80
---@field hl? string            高亮组 @default 'Comment'
---@field prefix? string        帧字符前缀 @default ' '
---@field virt_text_pos? 'eol'|'inline'|'right_align' @default 'eol'
---@field hl_mode? 'replace'|'combine'|'blend'  virt_text 高亮混合模式；'combine' 保留底层背景色（透明效果）@default 'combine'

--- 启动 loading 动画，返回 stop 函数（幂等）。
---@param opts VVLoadingOpts
---@return fun() stop
function M.start(opts)
  local buf         = opts.buf
  local get_row     = opts.get_row
  local frames      = opts.frames or M.presets.braille
  local interval_ms = opts.interval_ms or 80
  local hl          = opts.hl or 'Comment'
  local prefix      = opts.prefix ~= nil and opts.prefix or ' '
  local pos         = opts.virt_text_pos or 'eol'
  local hl_mode     = opts.hl_mode or 'combine'

  ns_counter = ns_counter + 1
  local ns = vim.api.nvim_create_namespace('vv-loading-' .. ns_counter)

  local frame   = 1
  local stopped = false

  local function draw()
    if stopped or not vim.api.nvim_buf_is_valid(buf) then return end
    local lnum = get_row()
    if not lnum then return end
    local row = lnum - 1
    vim.api.nvim_buf_clear_namespace(buf, ns, row, row + 1)
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0, {
      virt_text     = { { prefix .. frames[frame], hl } },
      virt_text_pos = pos,
      hl_mode       = hl_mode,
    })
    frame = (frame % #frames) + 1
  end

  draw()

  local timer = vim.uv.new_timer()
  timer:start(interval_ms, interval_ms, vim.schedule_wrap(function()
    if stopped or not vim.api.nvim_buf_is_valid(buf) then
      timer:stop()
      pcall(function() timer:close() end)
      return
    end
    draw()
  end))

  local function stop()
    if stopped then return end
    stopped = true
    timer:stop()
    pcall(function() timer:close() end)
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
  end

  return stop
end

return M
