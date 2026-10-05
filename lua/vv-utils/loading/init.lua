-- vv-utils.loading — 通用 loading 帧动画
--
-- 形态：
--   mark      buffer 内 (row, col) 的 virt_text，可贴在名字后（inline）或盖住固定槽位（overlay）
--   win_text  浮窗 title / footer，stop 时恢复原内容
--   ticker    只出帧不渲染，宿主自己拼进复合 UI
--   slot      同一位置多个并发请求共用一个显示（引用计数）
--   blocking  同步阻塞场景：画静态首帧 → redraw → 执行 → 清理
--
-- 所有动画共享按 interval_ms 分组的单一时钟（帧同步、无 timer 泄漏）；
-- 返回的 handle 支持 set_label / is_active / stop（幂等），owner 资源失效时自动停止

local Handle = require('vv-utils.loading.handle')
local Mark = require('vv-utils.loading.mark')
local WinText = require('vv-utils.loading.win_text')
local Slot = require('vv-utils.loading.slot')

local M = {}

---@type table<string, string[]>
M.presets = {
  braille = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' },
  dots    = { '⣾', '⣽', '⣻', '⢿', '⡿', '⣟', '⣯', '⣷' },
  bounce  = { '▏', '▎', '▍', '▌', '▋', '▊', '▉', '▊', '▋', '▌', '▍', '▎' },
}

local DEFAULT_INTERVAL_MS = 80
local HL = 'VVLoading'
local LABEL_HL = 'VVLoadingLabel'

local hl_registered = false
local function ensure_hl()
  if hl_registered then return end
  hl_registered = true
  -- 帧默认蓝色，label 默认低调的 Comment；均为 default，colorscheme / 用户可覆盖
  require('vv-utils.hl').register('vv-utils.loading.hl', {
    [HL] = { fg = '#7aa2f7' },
    [LABEL_HL] = { link = 'Comment' },
  })
end

--- 校验帧动画参数（frames / interval_ms），nil 视为取默认值；非法时抛错（不带位置信息）
--- opts 本身为 nil 视为全部取默认；非表（含 false）抛错
--- 所有 loading 形态在入口调用；宿主若推迟启动动画（如 prompt 的 spinner），应在自身入口提前调用，
--- 避免等到真正启动时才报错、留下半初始化状态
---@param opts? { frames?: string[], interval_ms?: integer }
---@param prefix? string 错误信息前缀，后接字段名 @default 'vv-utils.loading: '
function M.validate_frame_opts(opts, prefix)
  prefix = prefix or 'vv-utils.loading: '
  if opts == nil then return end
  if type(opts) ~= 'table' then error(prefix .. 'opts must be a table', 0) end

  local frames = opts.frames
  if frames ~= nil then
    local valid = type(frames) == 'table' and #frames > 0
    if valid then
      for i = 1, #frames do
        if type(frames[i]) ~= 'string' then
          valid = false
          break
        end
      end
    end
    if not valid then error(prefix .. 'frames must be a non-empty list of strings', 0) end
  end

  -- luv 把毫秒截断为整数：< 1（含 0.5 这类小数）会变成 repeat = 0，出两帧后停住但 handle 仍活跃；
  -- 非整数还会让 1.5 与 1 落进不同的时钟分组、实际间隔相同却不再帧同步，因此要求 >= 1 的整数
  local interval_ms = opts.interval_ms
  if interval_ms ~= nil
    and not (type(interval_ms) == 'number' and interval_ms >= 1 and interval_ms % 1 == 0) then
    error(prefix .. 'interval_ms must be an integer >= 1', 0)
  end
end

---@param opts VVLoadingCommonOpts
---@param static? boolean
---@return vv-utils.loading.HandleSpec
local function handle_spec(opts, static)
  M.validate_frame_opts(opts)
  return {
    frames = opts.frames or M.presets.braille,
    interval_ms = opts.interval_ms or DEFAULT_INTERVAL_MS,
    delay_ms = static and 0 or (opts.delay_ms or 0),
    label = opts.label,
    static = static,
    render = function() end,
  }
end

---@param opts VVLoadingMarkOpts
---@return VVLoadingMarkOpts
local function normalize_mark(opts)
  assert(opts.buf and opts.get_pos, 'vv-utils.loading.mark: buf and get_pos are required')
  ensure_hl()
  local pos = opts.pos or 'inline'
  return {
    -- 0 归一化为当前 buffer 的真实编号：否则每帧画到「那一刻的当前 buffer」，stop 也只清那一个
    buf = opts.buf == 0 and vim.api.nvim_get_current_buf() or opts.buf,
    get_pos = opts.get_pos,
    pos = pos,
    width = opts.width,
    prefix = opts.prefix or (pos == 'overlay' and '' or ' '),
    suffix = opts.suffix or '',
    hl = opts.hl or HL,
    label_hl = opts.label_hl or LABEL_HL,
    hl_mode = opts.hl_mode or 'combine',
    priority = opts.priority,
  }
end

---@param opts VVLoadingWinTextOpts
---@return VVLoadingWinTextOpts
local function normalize_win_text(opts)
  ensure_hl()
  assert(opts.win and (opts.slot == 'title' or opts.slot == 'footer'),
    "vv-utils.loading.win_text: win and slot ('title'|'footer') are required")
  return {
    -- 0 归一化为当前窗口的真实编号：否则 WinClosed pattern 为 '0' 永不匹配，且总是写到当时的当前窗口
    win = opts.win == 0 and vim.api.nvim_get_current_win() or opts.win,
    slot = opts.slot,
    format = opts.format or function(frame, label)
      if not label then return { { (' %s '):format(frame), HL } } end
      return { { ' ' .. frame, HL }, { (' %s '):format(label), LABEL_HL } }
    end,
  }
end

--- 在 buffer 指定位置显示 loading 帧
---@param opts VVLoadingMarkOpts
---@return vv-utils.loading.Handle
function M.mark(opts)
  return Mark.new(normalize_mark(opts), handle_spec(opts))
end

--- 在浮窗 title / footer 显示 loading 帧，stop 时恢复原内容
---@param opts VVLoadingWinTextOpts
---@return vv-utils.loading.Handle
function M.win_text(opts)
  return WinText.new(normalize_win_text(opts), handle_spec(opts))
end

--- 纯帧计时器：每帧调 on_frame(frame, label)，返回 false 即停止；不渲染任何东西，也不替调用方清理
---@param opts VVLoadingTickerOpts
---@return vv-utils.loading.Handle
function M.ticker(opts)
  assert(type(opts.on_frame) == 'function', 'vv-utils.loading.ticker: on_frame is required')
  local spec = handle_spec(opts)
  spec.render = function(frame, label) return opts.on_frame(frame, label) end
  return Handle.new(spec)
end

--- 同一 UI 位置多个并发请求共用一个显示
---@param create fun(): vv-utils.loading.Handle 计数 0→1 时调用，通常返回 M.mark / M.win_text
---@return vv-utils.loading.Slot
function M.slot(create)
  return Slot.new(create)
end

--- 同步阻塞执行 fn：先画静态首帧（或在命令行 echo）并 redraw，执行完清理后透传返回值
--- echo 文案不主动清除，由 fn 之后的结果消息覆盖；fn 抛错时先清理再原样重抛原始错误对象（不拼 traceback）
---@param opts VVLoadingBlockingOpts
---@param fn fun(...): ...
---@return ...
function M.blocking(opts, fn, ...)
  local handle
  if opts.mark then
    handle = Mark.new(normalize_mark(opts.mark), handle_spec(opts.mark, true))
  elseif opts.win_text then
    handle = WinText.new(normalize_win_text(opts.win_text), handle_spec(opts.win_text, true))
  elseif opts.echo then
    ensure_hl()
    vim.api.nvim_echo({ { opts.echo, LABEL_HL } }, false, {})
  end
  vim.cmd.redraw()

  local result = vim.F.pack_len(pcall(fn, ...))
  if handle then handle:stop() end
  if not result[1] then error(result[2], 0) end
  return unpack(result, 2, result.n)
end

return M

---@class VVLoadingCommonOpts
---@field frames? string[]     动画帧列表 @default M.presets.braille
---@field interval_ms? integer 每帧间隔毫秒，必须为 >= 1 的整数；同间隔的实例共享时钟 @default 80
---@field delay_ms? integer    超过该时长才开始显示，避免快操作闪烁 @default 0
---@field label? string        帧后附带的文案，可用 handle:set_label 更新 @default nil

---@class VVLoadingPos
---@field row integer  1-based 行号
---@field col? integer 0-based 字节列；超出行长时 clamp 到行尾 @default 0

---@class VVLoadingMarkOpts: VVLoadingCommonOpts
---@field buf integer 0 表示调用时的当前 buffer（入口即归一化为真实编号）
---@field get_pos fun(): VVLoadingPos|VVLoadingPos[]|nil 每帧调用；nil 隐藏，数组表示多处共用一个 handle
---@field pos? 'inline'|'overlay'|'eol'|'right_align' virt_text_pos；eol / right_align 忽略 col @default 'inline'
---@field width? integer 文本不足该显示宽度时右侧补空格，overlay 盖住固定槽位时使用 @default nil
---@field prefix? string 帧前缀 @default overlay 为 ''，其余为 ' '
---@field suffix? string 文本后缀（inline 插在文字前时常用 ' '） @default ''
---@field hl? string 帧（含 prefix / suffix / 补齐空格）的高亮组 @default 'VVLoading'（default 蓝色 #7aa2f7）
---@field label_hl? string label 的高亮组 @default 'VVLoadingLabel'（default link 到 Comment）
---@field hl_mode? 'replace'|'combine'|'blend' @default 'combine'
---@field priority? integer extmark 优先级 @default nil

---@class VVLoadingWinTextOpts: VVLoadingCommonOpts
---@field win integer 带边框的浮窗；0 表示调用时的当前窗口（入口即归一化为真实编号）
---@field slot 'title'|'footer'
---@field format? fun(frame: string, label: string?): string|[string, string][] @default 帧用 VVLoading、label 用 VVLoadingLabel 的 chunk 列表 ' <frame> <label> '

---@class VVLoadingTickerOpts: VVLoadingCommonOpts
---@field on_frame fun(frame: string, label: string?): boolean? 返回 false 停止 ticker

---@class VVLoadingBlockingOpts
---@field mark? VVLoadingMarkOpts
---@field win_text? VVLoadingWinTextOpts
---@field echo? string 无锚点时在命令行显示的静态文案
