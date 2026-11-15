-- 浮窗列表视图：居中浮窗 + 标签栏 + 分组列表 + 可展开详情，内容可反复刷新
--
-- 调用方只提供 page(view) → 「这一页有哪些分组和条目」，以及一组按键动作；
-- 窗口、遮罩、缩放重排、行号与条目的对应、重绘后的光标位置、页脚按键提示都由这里负责
--
-- 渲染是整页重写：条目数量在几百以内时比差量更新简单可靠，重绘前后按条目 id 恢复光标

require('vv-utils.ui_view.types')

local Hl = require('vv-utils.hl')
local Keys = require('vv-utils.keys')
local Rows = require('vv-utils.ui_rows')
local Window = require('vv-utils.ui_window')

local M = {}

Hl.register('vv-utils.ui_view', {
  VVViewTab = { link = 'CursorLine' },
  VVViewTabActive = { link = 'Visual' },
  VVViewTabKey = { link = 'Special' },
  VVViewBrand = { link = 'IncSearch' },
  VVViewSection = { link = 'Title' },
  VVViewCount = { link = 'Comment' },
  VVViewMuted = { link = 'Comment' },
  VVViewDetailKey = { link = 'Comment' },
  VVViewDetailValue = { link = 'String' },
})

local PADDING = '  '
local ITEM_INDENT = '  '
local DETAIL_INDENT = '      '
local RIGHT_PADDING = 2 -- 按内容定宽时，最宽的一行与右边框之间的留白
local FLOAT_MARGIN = 4 -- ui_window.centered_config 为编辑器边缘预留的默认总宽度

---@type VVUIViewConfig
local defaults = {
  width = 0.8,
  height = 0.8,
  border = 'rounded',
  backdrop = true,
  filetype = 'vv-view',
  desc_prefix = 'vv-view',
  tabs = {},
  actions = {},
  expand_key = '<CR>',
  close_keys = { 'q', '<Esc>' },
  section_keys = true,
  min_width = 40,
}

---@param value VVUIRowsRow|VVUIRowsChunk[]|string
---@return VVUIRowsRow
local function as_row(value)
  if type(value) == 'string' then return { chunks = { { value } } } end
  if value.chunks or value.text then
    return { chunks = Rows.chunks(value), virt_text = value.virt_text, virt_text_pos = value.virt_text_pos }
  end
  return { chunks = value }
end

---@param indent string
---@param row VVUIRowsRow
---@return VVUIRowsRow
local function indented(indent, row)
  local chunks = { { indent } }
  vim.list_extend(chunks, row.chunks)
  return { chunks = chunks, virt_text = row.virt_text, virt_text_pos = row.virt_text_pos }
end

---@param opts VVUIViewOpts
---@return VVUIViewHandle
function M.open(opts)
  vim.validate('opts', opts, 'table')
  vim.validate('opts.page', opts.page, 'function')

  ---@type VVUIViewConfig
  local config = vim.tbl_extend('force', vim.deepcopy(defaults), opts)

  local namespace = vim.api.nvim_create_namespace('')
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = config.filetype

  -- 'content' 模式下尺寸取上一次渲染的结果；首次渲染前先用最小值开窗，渲染后立即重排
  local fitted = { width = config.min_width, height = 1 }
  local fit_width, fit_height = config.width == 'content', config.height == 'content'

  local float = Window.open_float(buf, {
    width = fit_width and function() return fitted.width end or config.width,
    height = fit_height and function() return fitted.height end or config.height,
    border = config.border,
    backdrop = config.backdrop,
    title = config.title and { { ' ' .. config.title .. ' ', 'Title' } } or nil,
    chrome = { cursorline = true, scrolloff = 2 },
  })
  local win = float.win
  require('vv-utils.mouse').block_visual_drag(buf)

  local view = { buf = buf, win = win } ---@type VVUIViewHandle
  local closed = false
  local active_tab = config.tab or (config.tabs[1] and config.tabs[1].id)
  local expanded = {} ---@type table<string, boolean>

  -- 每次渲染重建
  local line_info = {} ---@type table<integer, VVUIViewLine> 1 基行号 → 该行属于什么
  local first_line = {} ---@type table<string, integer> 条目或分组 id → 首行
  local items = {} ---@type table<string, VVUIViewItem>
  local tab_spans = {} ---@type { id: string, from: integer, to: integer }[] 标签在标签栏里的显示列区间
  local tab_line ---@type integer?
  local content_col = {} ---@type table<integer, integer> 1 基行号 → 该行内容（去掉缩进）起始的字节列

  ---@return VVUIRowsRow?
  local function tab_bar()
    if #config.tabs == 0 and not config.brand then return nil end

    local chunks, column = { { PADDING } }, #PADDING
    tab_spans = {}

    local function pill(parts, id)
      local width = Rows.width(parts)
      if id then tab_spans[#tab_spans + 1] = { id = id, from = column, to = column + width } end
      vim.list_extend(chunks, parts)
      chunks[#chunks + 1] = { ' ' }
      column = column + width + 1
    end

    if config.brand then pill({ { ' ' .. config.brand .. ' ', 'VVViewBrand' } }) end
    for _, tab in ipairs(config.tabs) do
      local group = tab.id == active_tab and 'VVViewTabActive' or 'VVViewTab'
      local parts = { { ' ' .. tab.label .. ' ', group } }
      if tab.key then
        -- 键位叠在标签底色上：先铺标签组，再叠键位的前景色
        parts[#parts + 1] = { '(' .. Keys.display(tab.key) .. ')', { group, 'VVViewTabKey' } }
        parts[#parts + 1] = { ' ', group }
      end
      pill(parts, tab.id)
    end
    return { chunks = chunks }
  end

  ---光标所在行对应的定位点：重绘后据此找回位置
  ---@return string? id
  ---@return integer offset 相对该 id 首行的偏移（落在详情行时非零）
  local function anchor()
    if not vim.api.nvim_win_is_valid(win) then return nil, 0 end
    local line = vim.api.nvim_win_get_cursor(win)[1]
    local info = line_info[line]
    if not info or not info.id then return nil, 0 end
    return info.id, line - (first_line[info.id] or line)
  end

  ---@param action VVUIViewAction
  ---@return boolean 动作在当前标签下是否可用
  local function applies(action)
    if action.tab == nil then return true end
    if type(action.tab) == 'string' then return action.tab == active_tab end
    return vim.tbl_contains(action.tab, active_tab)
  end

  ---@return VVKeyHint[]
  local function footer_hints()
    local hints = {}
    for _, action in ipairs(config.actions) do
      if action.hint ~= false and applies(action) then
        local key = action.key
        if type(key) == 'table' and action.hint ~= 'all' then key = key[1] end
        hints[#hints + 1] = { key = key, desc = action.desc }
      end
    end
    hints[#hints + 1] = { key = config.close_keys[1], desc = 'Close' }
    return hints
  end

  local function update_footer()
    local chunks = Window.key_hints(footer_hints(), { max_width = vim.api.nvim_win_get_width(win) })
    pcall(vim.api.nvim_win_set_config, win, { footer = chunks or '', footer_pos = 'center' })
  end

  function view.refresh()
    if closed or not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then return end

    local anchor_id, anchor_offset = anchor()
    local page = config.page(view) or { sections = {} }

    local rows = {} ---@type VVUIRowsRow[]
    line_info, first_line, items, content_col = {}, {}, {}, {}

    ---@param indent string
    ---@param row VVUIRowsRow
    ---@param info? VVUIViewLine
    local function push(indent, row, info)
      -- 一个逻辑行可能含换行，展开成多条物理行后都归属同一个定位点
      for _, physical in ipairs(Rows.expand(indented(indent, row))) do
        rows[#rows + 1] = physical
        line_info[#rows] = info or { kind = 'text' }
        content_col[#rows] = #indent
        if info and info.id and not first_line[info.id] then first_line[info.id] = #rows end
      end
    end
    local function blank() push('', { chunks = {} }) end

    local bar = tab_bar()
    if bar then
      blank()
      push('', bar, { kind = 'tabs' })
      tab_line = #rows
      blank()
    else
      tab_line = nil
    end

    for _, row in ipairs(page.header or {}) do push(PADDING, as_row(row)) end
    if page.header and #page.header > 0 then blank() end

    local total = 0
    for index, section in ipairs(page.sections or {}) do
      -- 空行只放在分组之间：末尾不留，否则按内容定高的窗口会多出一行，光标也能停在上面
      if index > 1 then blank() end
      if section.title then
        local chunks = {}
        if type(section.title) == 'string' then
          chunks[#chunks + 1] = { section.title, 'VVViewSection' }
        else
          vim.list_extend(chunks, section.title)
        end
        local count = section.count
        if count == nil then count = #section.items end
        if count ~= false then chunks[#chunks + 1] = { ' (' .. tostring(count) .. ')', 'VVViewCount' } end
        push(PADDING, { chunks = chunks }, { kind = 'section', id = section.id })
      end

      for _, item in ipairs(section.items) do
        total = total + 1
        items[item.id] = item
        push(PADDING .. (section.title and ITEM_INDENT or ''), as_row(item.row), { kind = 'item', id = item.id })

        if expanded[item.id] and item.detail then
          local detail = type(item.detail) == 'function' and item.detail() or item.detail
          for _, row in ipairs(detail or {}) do
            push(PADDING .. DETAIL_INDENT, as_row(row), { kind = 'detail', id = item.id })
          end
        end
      end
    end

    if total == 0 and page.empty then push(PADDING, as_row(page.empty)) end

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
    Rows.set_rendered_lines(buf, namespace, vim.iter(rows):map(function(row) return Rows.render(row)[1] end):totable())
    vim.bo[buf].modifiable = false

    -- 按定位点恢复光标；定位点消失（条目被过滤掉、切了标签）时落到第一个条目
    local target = anchor_id and first_line[anchor_id]
    if target then
      target = target + anchor_offset
      -- 详情被收起后偏移可能越界到别的条目上
      if not line_info[target] or line_info[target].id ~= anchor_id then target = first_line[anchor_id] end
    end
    if not target then
      for line = 1, #rows do
        if line_info[line].kind == 'item' then
          target = line
          break
        end
      end
    end
    target = math.min(target or 1, math.max(#rows, 1))

    -- 没有条目时高亮当前行只会误导：没有可操作的对象
    vim.api.nvim_set_option_value('cursorline', total > 0, { win = win, scope = 'local' })

    if page.title ~= nil then
      local title = type(page.title) == 'string' and { { ' ' .. page.title .. ' ', 'Title' } } or page.title
      pcall(vim.api.nvim_win_set_config, win, { title = title, title_pos = 'center' })
    end

    if fit_width or fit_height then
      local width = config.min_width
      for _, row in ipairs(rows) do
        local virt = row.virt_text and (Rows.width(row.virt_text) + 1) or 0
        width = math.max(width, Rows.width(row.chunks) + virt + RIGHT_PADDING)
      end
      -- 页脚提示完整放得下，窄内容不至于把提示截成省略号
      local hints = Window.key_hints(footer_hints())
      if hints then width = math.max(width, Rows.width(hints)) end
      fitted.width, fitted.height = width, math.max(#rows, 1)
      float.relayout()
    end

    pcall(vim.api.nvim_win_set_cursor, win, { target, content_col[target] or 0 })
    update_footer()
  end

  ---@return VVUIViewItem? item 光标所在的条目（落在它的详情行上也算）
  function view.item()
    if closed or not vim.api.nvim_win_is_valid(win) then return nil end
    local info = line_info[vim.api.nvim_win_get_cursor(win)[1]]
    if not info or (info.kind ~= 'item' and info.kind ~= 'detail') then return nil end
    return items[info.id]
  end

  ---@param id string 条目或分组 id
  ---@return integer? line 1 基行号；当前页没有它时为 nil。供 loading.mark 的 get_pos 回查
  function view.line_of(id)
    return first_line[id]
  end

  ---@param id string 条目或分组 id
  ---@return integer? line 1 基行号
  ---@return integer? col 该行内容（去掉缩进）起始的字节列，0 基；在条目内容后追加标记时以它为基准
  function view.pos_of(id)
    local line = first_line[id]
    if not line then return nil, nil end
    return line, content_col[line] or 0
  end

  ---一个条目行（不含视图自己加的缩进）最多能占多少显示列
  ---
  ---按内容定宽时窗口宽度由内容决定，不能反过来拿窗口宽度截断内容；这里给出编辑器允许的上限
  ---@param grouped? boolean 条目所在分组是否有标题（有标题时条目多缩进一层） @default false
  ---@return integer
  function view.item_width(grouped)
    local outer = fit_width and (vim.o.columns - FLOAT_MARGIN) or vim.api.nvim_win_get_width(win)
    local indent = #PADDING + (grouped and #ITEM_INDENT or 0)
    return math.max(1, outer - indent - RIGHT_PADDING)
  end

  ---@return string? id 当前标签
  function view.tab()
    return active_tab
  end

  ---@param id string
  function view.set_tab(id)
    if closed or id == active_tab then return end
    for _, tab in ipairs(config.tabs) do
      if tab.id == id then
        active_tab = id
        if config.on_tab then config.on_tab(view, id) end
        -- 换页后旧的光标与滚动位置没有意义：回到顶部，光标落在第一个条目
        pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
        view.refresh()
        pcall(vim.api.nvim_win_call, win, function() vim.fn.winrestview({ topline = 1 }) end)
        return
      end
    end
  end

  ---@param step integer 正数向后、负数向前，首尾相接
  function view.cycle_tab(step)
    for index, tab in ipairs(config.tabs) do
      if tab.id == active_tab then
        return view.set_tab(config.tabs[(index - 1 + step) % #config.tabs + 1].id)
      end
    end
  end

  ---展开或收起条目的详情
  ---@param id? string 缺省为光标所在条目
  ---@param state? boolean 缺省为取反
  function view.toggle(id, state)
    local item = id and items[id] or view.item()
    if not item or not item.detail then return end
    if state == nil then state = not expanded[item.id] end
    expanded[item.id] = state or nil
    view.refresh()
    -- 从详情行上收起时回到条目本身
    local line = first_line[item.id]
    if not state and line then pcall(vim.api.nvim_win_set_cursor, win, { line, content_col[line] or 0 }) end
  end

  ---@param id string
  ---@return boolean
  function view.is_expanded(id)
    return expanded[id] == true
  end

  ---@param id string 条目或分组 id
  function view.focus(id)
    local line = first_line[id]
    if line then pcall(vim.api.nvim_win_set_cursor, win, { line, content_col[line] or 0 }) end
  end

  function view.is_open()
    return not closed and vim.api.nvim_win_is_valid(win)
  end

  function view.close()
    if closed then return end
    closed = true
    float.close()
    if config.on_close then config.on_close() end
  end

  ---窗口已被外部方式关掉：调用方的收尾立即执行，自己的窗口清理留到事件结束后
  local function closed_externally()
    if closed then return end
    closed = true
    -- WinClosed 期间不能再关别的窗口（遮罩）
    vim.schedule(float.close)
    if config.on_close then config.on_close() end
  end

  ---@param step integer
  local function jump_section(step)
    local line = vim.api.nvim_win_get_cursor(win)[1]
    local last = vim.api.nvim_buf_line_count(buf)
    local index = line + step
    while index >= 1 and index <= last do
      if line_info[index] and line_info[index].kind == 'section' then
        -- 落在分组的第一个条目上，标题行本身没有动作
        local landing = (line_info[index + 1] and line_info[index + 1].kind == 'item') and index + 1 or index
        if landing ~= line then return pcall(vim.api.nvim_win_set_cursor, win, { landing, content_col[landing] or 0 }) end
      end
      index = index + step
    end
  end

  ---@param lhs string
  ---@param rhs fun()
  ---@param desc string
  local function map(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, {
      buffer = buf,
      nowait = true,
      silent = true,
      desc = config.desc_prefix .. ': ' .. desc,
    })
  end

  for _, action in ipairs(config.actions) do
    local keys = type(action.key) == 'table' and action.key or { action.key }
    for _, lhs in ipairs(keys) do
      map(lhs, function()
        if applies(action) then action.run(view, view.item()) end
      end, action.desc)
    end
  end

  local taken = {}
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do taken[mapping.lhsraw] = true end
  ---调用方的动作优先：内置键只在没被占用时才绑
  local function map_default(lhs, rhs, desc)
    if lhs and lhs ~= '' and not taken[vim.keycode(lhs)] then map(lhs, rhs, desc) end
  end

  for _, lhs in ipairs(config.close_keys) do map_default(lhs, view.close, 'Close') end
  if config.expand_key then map_default(config.expand_key, function() view.toggle() end, 'Toggle details') end
  if config.section_keys then
    map_default(']]', function() jump_section(1) end, 'Next section')
    map_default('[[', function() jump_section(-1) end, 'Previous section')
  end

  if #config.tabs > 1 then
    map_default('<Tab>', function() view.cycle_tab(1) end, 'Next tab')
    map_default('<S-Tab>', function() view.cycle_tab(-1) end, 'Previous tab')
    for _, tab in ipairs(config.tabs) do
      if tab.key then map_default(tab.key, function() view.set_tab(tab.id) end, 'Go to ' .. tab.label) end
    end
    map_default('<LeftRelease>', function()
      local mouse = vim.fn.getmousepos()
      if mouse.winid ~= win or mouse.line ~= tab_line then return end
      -- 标签栏全是单宽字符之外还可能有图标，按显示列命中
      local column = vim.fn.virtcol({ mouse.line, mouse.column }) - 1
      for _, span in ipairs(tab_spans) do
        if column >= span.from and column < span.to then return view.set_tab(span.id) end
      end
    end, 'Select tab')
  end

  local group = vim.api.nvim_create_augroup('vv-utils.ui_view.' .. buf, { clear = true })
  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    pattern = tostring(win),
    -- 被 :q、<C-w>c 等外部方式关闭时同样走一遍收尾
    callback = closed_externally,
  })
  vim.api.nvim_create_autocmd('VimResized', {
    group = group,
    -- 等 ui_window 重排完再画：页脚提示与调用方的列宽都依赖新的窗口宽度
    callback = function() vim.schedule(view.refresh) end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = buf,
    callback = function() pcall(vim.api.nvim_del_augroup_by_id, group) end,
  })

  view.refresh()
  return view
end

return M
