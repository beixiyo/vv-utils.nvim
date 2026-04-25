-- vv-utils.help_panel — 通用 keymap 帮助浮窗
--
-- 反读指定 buffer 的 normal 模式 keymap（按 desc 前缀过滤），按类别分组
-- 以 icon + key → action 的方式渲染在圆角浮窗中，q / <Esc> 关闭
--
-- 使用方：
--   require('vv-utils.help_panel').open({
--     source_buf  = state.buf,
--     desc_prefix = 'vv-explorer: ',
--     actions     = { open = { cat = 'Navigate', icon = '' }, ... },
--     categories  = { 'Navigate', 'View', ... },
--     title       = 'vv-explorer keymaps',
--     title_icon  = '',
--     filetype    = 'vv-explorer-help',
--   })

local hl = require('vv-utils.hl')

local M = {}
local ns = vim.api.nvim_create_namespace('vv-utils.help_panel')

hl.register('vv-utils.help_panel.hl', {
  VVHelpTitle    = { link = 'Title' },
  VVHelpCategory = { link = 'Type' },
  VVHelpKey      = { link = 'Constant' },
  VVHelpAction   = { link = 'Normal' },
  VVHelpIcon     = { link = 'Special' },
  VVHelpArrow    = { link = 'Comment' },
  VVHelpFooter   = { link = 'Comment' },
})

---@class VVHelpActionMeta
---@field cat string      分类名（用于分组）
---@field icon? string    nerd-font 图标字符

---@class VVHelpPanelOpts
---@field source_buf integer                              从哪个 buffer 读取 keymap
---@field desc_prefix string                              只抓 desc 匹配 '^<prefix>(.+)$' 的键位
---@field actions? table<string, VVHelpActionMeta>        action 名 → 分类/图标（未命中走 'Other'）
---@field categories? string[]                            分类渲染顺序，未提及的分类归入 'Other'
---@field title? string                                   浮窗顶部标题文本
---@field title_icon? string                              标题前的图标
---@field filetype? string                                浮窗 buffer 的 filetype

---@param opts VVHelpPanelOpts
---@return table<string, {lhs:string, action:string, icon:string}[]>
local function collect(opts)
  local by_cat = {}
  local maps = vim.api.nvim_buf_get_keymap(opts.source_buf, 'n')
  local pattern = '^' .. vim.pesc(opts.desc_prefix) .. '(.+)$'
  for _, m in ipairs(maps) do
    local desc = m.desc or ''
    local action = desc:match(pattern)
    if action then
      local meta = (opts.actions and opts.actions[action]) or { cat = 'Other', icon = '' }
      by_cat[meta.cat] = by_cat[meta.cat] or {}
      table.insert(by_cat[meta.cat], { lhs = m.lhs, action = action, icon = meta.icon or '' })
    end
  end
  for _, rows in pairs(by_cat) do
    table.sort(rows, function(a, b)
      if a.action == b.action then return a.lhs < b.lhs end
      return a.action < b.action
    end)
  end
  return by_cat
end

---@param opts VVHelpPanelOpts
function M.open(opts)
  assert(opts and opts.source_buf and opts.desc_prefix,
    'help-panel: source_buf & desc_prefix required')

  local by_cat = collect(opts)
  local ordered_cats = {}
  for _, c in ipairs(opts.categories or {}) do ordered_cats[#ordered_cats + 1] = c end
  -- 追加 Other（若未显式声明）
  local has_other = false
  for _, c in ipairs(ordered_cats) do if c == 'Other' then has_other = true break end end
  if not has_other then ordered_cats[#ordered_cats + 1] = 'Other' end

  local cats = {}
  for _, c in ipairs(ordered_cats) do
    if by_cat[c] and #by_cat[c] > 0 then cats[#cats + 1] = c end
  end
  if #cats == 0 then return end

  -- 统一 key 列宽
  local key_w = 0
  for _, rows in pairs(by_cat) do
    for _, r in ipairs(rows) do
      if #r.lhs > key_w then key_w = #r.lhs end
    end
  end
  key_w = math.max(key_w, 4)

  local lines, hls = {}, {}
  local function add_hl(row, col, end_col, hl_name)
    hls[#hls + 1] = { row = row, col = col, end_col = end_col, hl = hl_name }
  end

  -- title
  local title_icon = opts.title_icon or ''
  local title_text = opts.title or 'keymaps'
  local title = '  ' .. title_icon .. (title_icon ~= '' and '  ' or '') .. title_text
  lines[#lines + 1] = title
  add_hl(#lines - 1, 0, #title, 'VVHelpTitle')
  lines[#lines + 1] = ''

  for ci, cat in ipairs(cats) do
    local header = '  ' .. cat
    lines[#lines + 1] = header
    add_hl(#lines - 1, 0, #header, 'VVHelpCategory')

    for _, r in ipairs(by_cat[cat]) do
      local icon = r.icon or ''
      local icon_pad = math.max(0, 2 - vim.fn.strdisplaywidth(icon))
      local line = '   '
      local icon_start = #line
      line = line .. icon .. string.rep(' ', icon_pad) .. ' '
      local icon_end = icon_start + #icon

      local key_start = #line
      line = line .. string.format('%-' .. key_w .. 's', r.lhs)
      local key_end = key_start + #r.lhs

      local arrow_start = #line
      line = line .. '  → '
      local arrow_end = #line

      local action_start = #line
      line = line .. r.action
      local action_end = #line

      lines[#lines + 1] = line
      local lnum = #lines - 1
      if #icon > 0 then add_hl(lnum, icon_start, icon_end, 'VVHelpIcon') end
      add_hl(lnum, key_start, key_end, 'VVHelpKey')
      add_hl(lnum, arrow_start, arrow_end, 'VVHelpArrow')
      add_hl(lnum, action_start, action_end, 'VVHelpAction')
    end

    if ci < #cats then lines[#lines + 1] = '' end
  end

  lines[#lines + 1] = ''
  local footer = '  q / <Esc> to close'
  lines[#lines + 1] = footer
  add_hl(#lines - 1, 0, #footer, 'VVHelpFooter')

  local max_w = 0
  for _, l in ipairs(lines) do
    local w = vim.fn.strdisplaywidth(l)
    if w > max_w then max_w = w end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = opts.filetype or 'vv-help'
  for _, h in ipairs(hls) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, h.row, h.col, {
      end_col = h.end_col, hl_group = h.hl,
    })
  end

  local ui = vim.api.nvim_list_uis()[1]
  local height = math.min(#lines, (ui and ui.height or 40) - 4)
  local width = math.min(max_w + 4, (ui and ui.width or 80) - 4)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor', style = 'minimal', border = 'rounded',
    title = ' help ', title_pos = 'center',
    row = math.floor(((ui and ui.height or 40) - height) / 2),
    col = math.floor(((ui and ui.width or 80) - width) / 2),
    width = width, height = height,
  })
  vim.wo[win].cursorline = true
  -- 光标落在首个 keymap 行（title + blank + cat header = 3 → first keymap = 4）
  pcall(vim.api.nvim_win_set_cursor, win, { 4, 0 })

  local close = function()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end
  vim.keymap.set('n', 'q', close, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set('n', '<Esc>', close, { buffer = buf, nowait = true, silent = true })
end

return M
