-- vv-utils.ui_peek — 通用内容浮窗（源码快照预览）
--
-- 把内容行以只读快照 buffer 展示在源光标附近的浮窗：几何与锚点、语法高亮、
-- 落点高亮、键位和窗口生命周期全部由本模块负责；调用方只决定内容、落点与
-- 交互策略（LSP 请求、多结果切换等）。全局单浮窗：新 show 复用窗口并替换内容
-- 快照是 nofile buffer，浮窗窗口选项不继承全局 statuscolumn 等自绘左列

require('vv-utils.ui_peek.types')

local UIRows = require('vv-utils.ui_rows')

local M = {}

local namespace = vim.api.nvim_create_namespace('vv-utils.ui_peek')
local group = vim.api.nvim_create_augroup('VVUtilsUiPeek', { clear = true })

local state = nil ---@type table? { win, buf, source_win, hl_buf, applied_keys, on_close }

---@type VVUiPeekConfig
local defaults = {
  min_width = 40,
  min_height = 8,
  border = 'rounded',
  title_pos = 'center',
  zindex = 50,
  win_options = {
    wrap = false,
    spell = false,
    cursorline = true,
    signcolumn = 'no',
    foldcolumn = '0',
    statuscolumn = '',
    number = true,
  },
  close_keys = { 'q', '<Esc>' },
  keys = {},
  hl = { line = 'CursorLine', range = 'Search' },
  max_lines = 0,
}
local config = vim.deepcopy(defaults)

local function clamp(value, min, max)
  if value < min then return min end
  if max ~= nil and value > max then return max end
  return value
end

local function slice(lines, from, to)
  local result = {}
  for index = from + 1, to do
    result[#result + 1] = lines[index]
  end
  return result
end

---配置或 show 项的函数形态解析；函数抛错或返回非法类型时回退 fallback
---@param value any
---@param ctx VVUiPeekContext
---@param fallback any
---@return any
local function resolve(value, ctx, fallback)
  if type(value) == 'function' then
    local ok, result = pcall(value, ctx)
    if ok then return result end
    return fallback
  end
  if value == nil then return fallback end
  return value
end

local function byte_col(lines, position, encoding)
  local line = lines[position.line + 1] or ''
  if encoding == 'utf-8' then return math.min(position.character or 0, #line) end
  local ok, col = pcall(vim.str_byteindex, line, encoding or 'utf-16', position.character or 0, false)
  if not ok or type(col) ~= 'number' then return math.min(position.character or 0, #line) end
  return math.min(col, #line)
end

---自绘行展开：rows → 物理行渲染结果（含高亮与 virt_text）；非 rows 模式返回 nil
local function render_rows(item)
  if item.rows == nil then return nil end
  assert(type(item.rows) == 'table' and #item.rows > 0, 'vv-utils.ui_peek: rows must be a non-empty list')
  local rendered = {}
  for _, row in ipairs(item.rows) do
    vim.list_extend(rendered, UIRows.render(row))
  end
  return rendered
end

---读取内容行：lines 直接使用；uri/path 直读文件系统，非文件 URI（如 jdt://）回退 bufload
local function read_lines(item)
  if type(item.lines) == 'table' and #item.lines > 0 then return item.lines end
  local uri = item.uri or (item.path and vim.uri_from_fname(item.path))
  if type(uri) ~= 'string' or uri == '' then return nil end
  -- readfile 的第三参 0 表示不读任何行，仅在 max_lines > 0 时传入
  local limit = config.max_lines and config.max_lines > 0 and config.max_lines or nil
  local ok, lines = pcall(vim.fn.readfile, vim.uri_to_fname(uri), '', limit)
  if ok and type(lines) == 'table' and #lines > 0 then return lines end
  local buf = vim.uri_to_bufnr(uri)
  vim.fn.bufload(buf)
  local loaded = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #loaded > 0 then return loaded end
  return nil
end

local function detect_filetype(item)
  if type(item.filetype) == 'string' and item.filetype ~= '' then return item.filetype end
  if item.rows ~= nil then return nil end
  local path = item.path or (item.uri and vim.uri_to_fname(item.uri) or '')
  if path ~= '' then
    local ok, lang = pcall(vim.filetype.match, { filename = path })
    if ok and type(lang) == 'string' and lang ~= '' then return lang end
  end
  return nil
end

---源窗口光标的屏幕行列（1-based）；与当前焦点在哪无关，供浮窗定位
local function source_cursor_screen(win)
  local base = vim.fn.win_screenpos(win)
  local row, col
  vim.api.nvim_win_call(win, function()
    row, col = vim.fn.winline(), vim.fn.wincol()
  end)
  return base[1] + row - 1, base[2] + col - 1
end

---构建函数配置可见的上下文；窗口尺寸在 geometry 中确定后写回
local function context(buf, lines, item, filetype)
  local line_count = #lines
  local range = item.range
  local span = range and (range['end'].line - range.start.line + 1) or 1
  local ctx = {
    buf = buf,
    lines = lines,
    line_count = line_count,
    span = span,
    range = range,
    cursor = item.cursor,
    filetype = filetype,
    source_win = item.source_win,
    number_width = math.max(vim.o.numberwidth, #tostring(line_count) + 2),
    max_line_width = 20,
    screen = {
      columns = vim.o.columns,
      lines = vim.o.lines,
      available = math.max(4, vim.o.lines - vim.o.cmdheight - 2),
    },
  }
  local center = range and range.start.line or item.cursor and item.cursor.line or 0
  local from = clamp(center - 5, 0, line_count - 1)
  for _, line in ipairs(slice(lines, from, math.min(from + 50, line_count))) do
    ctx.max_line_width = math.max(ctx.max_line_width, vim.fn.strdisplaywidth(line))
  end
  return ctx
end

---默认锚点策略：源光标下方优先，空间不足翻上方；上下都不够时贴底
local function default_position(ctx)
  local screen_row, screen_col = source_cursor_screen(ctx.source_win)
  local bottom = vim.o.lines - vim.o.cmdheight - (vim.o.laststatus == 0 and 0 or 1)
  local anchor, row
  if bottom - screen_row >= ctx.height then
    anchor, row = 'NW', screen_row
  elseif screen_row - 1 >= ctx.height then
    anchor, row = 'SW', screen_row - 1
  else
    anchor, row = 'NW', math.max(1, bottom - ctx.height)
  end
  local col = clamp(screen_col - 1, 1, math.max(1, vim.o.columns - ctx.width - 2))
  return { anchor = anchor, row = row, col = col }
end

---解析一个尺寸维度：number、fun(ctx) 或 { ratio = n }，非法值回退 fallback
---
---ratio 的基准由轴决定，不逐项声明：宽度类取 editor 列数，高度类取 editor 可用行数
---（与浮窗 relative = 'editor' 的坐标系一致）
---@param value any
---@param ctx VVUiPeekContext
---@param axis 'columns'|'available'
---@param fallback number
---@return number
local function dimension(value, ctx, axis, fallback)
  local resolved = resolve(value, ctx, fallback)
  if type(resolved) == 'table' then
    local ratio = tonumber(resolved.ratio)
    if not ratio or ratio <= 0 or ratio > 1 then return fallback end
    return math.floor(ctx.screen[axis] * ratio)
  end
  return tonumber(resolved) or fallback
end

---由配置计算窗口几何与锚点；解析出的宽高写回 ctx 供 position 函数使用
local function geometry(ctx, cfg, item)
  local min_height = math.max(1, math.floor(dimension(cfg.min_height, ctx, 'available', defaults.min_height)))
  local min_width = math.max(10, math.floor(dimension(cfg.min_width, ctx, 'columns', defaults.min_width)))
  local max_height = dimension(cfg.max_height, ctx, 'available', ctx.screen.available)
  local max_width = dimension(cfg.max_width, ctx, 'columns', ctx.screen.columns)
  ctx.height = clamp(
    math.floor(dimension(cfg.height, ctx, 'available', ctx.span + 2)),
    min_height,
    math.max(min_height, max_height)
  )
  ctx.width = clamp(
    math.floor(dimension(cfg.width, ctx, 'columns', ctx.max_line_width + ctx.number_width + 2)),
    min_width,
    math.max(min_width, max_width)
  )
  local position = resolve(cfg.position, ctx, nil)
  if type(position) ~= 'table' then position = default_position(ctx) end
  local title = item.title ~= nil and resolve(item.title, ctx, nil) or resolve(cfg.title, ctx, nil)
  local win_config = {
    relative = 'editor',
    anchor = position.anchor or 'NW',
    row = position.row or 1,
    col = position.col or 1,
    width = ctx.width,
    height = ctx.height,
    border = cfg.border,
    zindex = cfg.zindex,
  }
  -- nvim 要求 title 与 title_pos 成对出现；无标题时两个键都不传
  if type(title) == 'string' and title ~= '' then
    win_config.title = title
    win_config.title_pos = cfg.title_pos
  end
  return win_config
end

local function clear_highlight()
  if state and state.hl_buf and vim.api.nvim_buf_is_valid(state.hl_buf) then
    pcall(vim.api.nvim_buf_clear_namespace, state.hl_buf, namespace, 0, -1)
  end
  if state then state.hl_buf = nil end
end

local function highlight(buf, item, lines, cfg)
  local range = item.range
  if not range then return end
  state.hl_buf = buf
  local last = math.min(range['end'].line, vim.api.nvim_buf_line_count(buf) - 1)
  -- 整行底色用 hl_group + hl_eol 而非 line_hl_group：后者会无视 priority 盖掉同行 extmark 的 bg，
  -- 导致 range 高亮只能靠 fg 区分
  local ok_line = pcall(vim.api.nvim_buf_set_extmark, buf, namespace, range.start.line, 0, {
    end_row = range.start.line + 1,
    end_col = 0,
    hl_group = cfg.hl.line,
    hl_eol = true,
    strict = false,
    priority = 150,
  })
  if not ok_line then return end
  local start_col = byte_col(lines, range.start, item.encoding)
  local end_col = last > range.start.line and #lines[last + 1] or byte_col(lines, range['end'], item.encoding)
  if end_col < start_col then end_col = start_col end
  if last > range.start.line or end_col > start_col then
    pcall(vim.api.nvim_buf_set_extmark, buf, namespace, range.start.line, start_col, {
      end_row = last,
      end_col = end_col,
      hl_group = cfg.hl.range,
      -- 覆盖自绘行高亮（ui_rows 默认 priority）与 treesitter，落点标记永远在最上层
      priority = 5000,
    })
  end
end

local function clear_keymaps(buf, applied)
  for _, lhs in ipairs(applied or {}) do
    pcall(vim.api.nvim_buf_del_keymap, buf, 'n', lhs)
  end
end

local function apply_keymaps(buf, cfg)
  local applied = {}
  local function map(lhs, callback)
    vim.api.nvim_buf_set_keymap(buf, 'n', lhs, '', {
      noremap = true,
      nowait = true,
      silent = true,
      callback = callback,
    })
    applied[#applied + 1] = lhs
  end
  if cfg.close_keys ~= false then
    for _, key in ipairs(cfg.close_keys or defaults.close_keys) do
      map(key, function() M.close(true) end)
    end
  end
  for lhs, callback in pairs(cfg.keys or {}) do
    if callback ~= false then map(lhs, callback) end
  end
  return applied
end

---把内容展示到浮窗：复用窗口与快照 buffer，重设内容、高亮、光标、键位与几何
---@param item VVUiPeekItem
---@param override? VVUiPeekConfig 覆盖 setup 配置（含函数形态），仅本次生效
---@return { win: integer, buf: integer, source_win: integer }? info
---@return string? error
function M.show(item, override)
  assert(type(item) == 'table', 'vv-utils.ui_peek: show requires an item table')
  item = vim.deepcopy(item)
  item.source_win = item.source_win or vim.api.nvim_get_current_win()
  item.enter = item.enter ~= false
  -- 自绘行坐标即字节坐标；文件/uri 内容才需要 LSP offset encoding
  if item.rows ~= nil and item.encoding == nil then item.encoding = 'utf-8' end
  local cfg = override and vim.tbl_deep_extend('force', config, override) or config

  local rendered = render_rows(item)
  local lines = rendered and vim.tbl_map(function(entry) return entry.text end, rendered) or read_lines(item)
  if not lines or #lines == 0 then
    M.close(true)
    return nil, 'empty content'
  end

  local buf = state and state.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'wipe'
    state = state or {}
    state.buf = buf
  end

  -- rows 模式不做语法高亮猜测，也要清掉复用 buffer 残留的上次 filetype
  local filetype = detect_filetype(item)
  if filetype then
    if vim.bo[buf].filetype ~= filetype then
      vim.bo[buf].filetype = filetype
      -- 快照 buffer 不经过 nvim-treesitter 的 attach 流程，手动启动语法高亮
      pcall(vim.treesitter.start, buf, filetype)
    end
  elseif vim.bo[buf].filetype ~= '' then
    vim.bo[buf].filetype = ''
    pcall(vim.treesitter.stop, buf)
  end
  -- 写入前清空本模块在该快照 buffer 上的全部标记，rows 自绘与落点高亮随后重建
  state.hl_buf = nil
  pcall(vim.api.nvim_buf_clear_namespace, buf, namespace, 0, -1)
  vim.bo[buf].modifiable = true
  if rendered then
    UIRows.set_rendered_lines(buf, namespace, rendered)
  else
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end
  vim.bo[buf].modifiable = false

  local ctx = context(buf, lines, item, filetype)
  local win_config = geometry(ctx, cfg, item)

  local win = state.win
  if not win or not vim.api.nvim_win_is_valid(win) then
    win = vim.api.nvim_open_win(buf, item.enter, win_config)
    state.win = win
    for key, value in pairs(cfg.win_options or {}) do
      pcall(function() vim.wo[win][key] = value end)
    end
  else
    if vim.api.nvim_win_get_buf(win) ~= buf then vim.api.nvim_win_set_buf(win, buf) end
    vim.api.nvim_win_set_config(win, win_config)
  end
  if item.enter and vim.api.nvim_get_current_win() ~= win then
    vim.api.nvim_set_current_win(win)
  end

  clear_keymaps(buf, state.applied_keys)
  state.applied_keys = apply_keymaps(buf, cfg)
  state.source_win = item.source_win
  -- override 的 on_close 仅本次生效；close 时回退当前 setup 配置，允许后置注册
  state.on_close = override and override.on_close or nil

  clear_highlight()
  highlight(buf, item, lines, cfg)

  local cursor_line = item.cursor and item.cursor.line or (item.range and item.range.start.line or 0)
  local cursor_col = item.cursor and item.cursor.col
    or (item.range and byte_col(lines, item.range.start, item.encoding) or 0)
  vim.api.nvim_win_set_cursor(win, { clamp(cursor_line, 0, vim.api.nvim_buf_line_count(buf) - 1) + 1, cursor_col })
  vim.api.nvim_win_call(win, function() vim.cmd('normal! zz') end)

  -- 源窗口关闭时浮窗失去挂载点，一并关闭
  vim.api.nvim_clear_autocmds({ group = group })
  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    pattern = tostring(item.source_win),
    callback = function()
      if state and state.source_win == item.source_win then M.close(false) end
    end,
  })
  return { win = win, buf = buf, source_win = item.source_win }
end

---关闭浮窗并释放快照 buffer；focus_source 默认回源窗口
---@param focus_source? boolean
function M.close(focus_source)
  local active = state
  state = nil
  if not active then return end
  local on_close = active.on_close or config.on_close
  clear_highlight()
  local win = active.win
  if win and vim.api.nvim_win_is_valid(win) then
    local focused = vim.api.nvim_get_current_win() == win
    pcall(vim.api.nvim_win_close, win, true)
    if focused and focus_source ~= false and vim.api.nvim_win_is_valid(active.source_win) then
      vim.api.nvim_set_current_win(active.source_win)
    end
  end
  if active.buf and vim.api.nvim_buf_is_valid(active.buf) then
    pcall(vim.api.nvim_buf_delete, active.buf, { force = true })
  end
  vim.api.nvim_clear_autocmds({ group = group })
  if type(on_close) == 'function' then pcall(on_close) end
end

---浮窗是否仍打开
---@return boolean
function M.is_open()
  return state ~= nil and state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

---当前浮窗信息
---@return { win: integer, buf: integer, source_win: integer }?
function M.current()
  if not M.is_open() then return nil end
  return { win = state.win, buf = state.buf, source_win = state.source_win }
end

---归一化模块默认配置；重复 setup 覆盖上次
---@param opts? VVUiPeekConfig
function M.setup(opts)
  config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
  assert(
    config.close_keys == false or type(config.close_keys) == 'table',
    'close_keys must be a key list or false'
  )
  assert(type(config.win_options) == 'table', 'win_options must be a table')
  assert(type(config.hl) == 'table', 'hl must be a table')
  assert(config.max_lines == nil or type(config.max_lines) == 'number', 'max_lines must be a number')
end

---查询配置副本
---@return VVUiPeekConfig
function M.get_config() return vim.deepcopy(config) end

return M
