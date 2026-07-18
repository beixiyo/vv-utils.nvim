-- vv-utils.prompt — 底部锚定的双行浮动输入框（filter prompt）
--
-- 抽取自 vv-flow/filter.lua + vv-explorer/prompt.lua（两者 ~90% 逐字同构）
-- 适用场景：贴在某个侧栏 / 列表窗口底部、边打边过滤的输入框
--
-- 两行布局（buffer 实际 2 行，避开 floating window 里 virt_lines 不稳的坑）：
--   line 0 = 空串，extmark overlay 画 label：mode badge / 静态 label + <S-Tab> 提示 + 实时状态
--   line 1 = 用户输入；空时 overlay 显示 placeholder（第一字符即覆盖），输入行保持干净
--
-- 光标锁在 line 1：CursorMoved/CursorMovedI 无差别拉回（覆盖键盘/鼠标/折叠跳转，比 keymap 黑名单稳）
-- 交互：边打边过滤（debounce）→ on_change；<CR> → on_accept（保留过滤态）；
--       <Esc> / normal q / 失焦 → on_cancel。先 stopinsert 再 close（否则 Insert 模式残留写错 buffer）
--
-- spinner 走「push 模型」：宿主在自己的异步流程里调 handle.set_busy(true,'…') / set_busy(false)，
-- 由本模块自己转帧——不反向读宿主 state（消除耦合）
--
-- M.open(anchor_win, opts) → handle{ close, redraw, set_busy, set_status }；
-- 宿主在自身销毁时调 handle.close()，连带关掉浮窗（幂等）

local hl = require('vv-utils.hl')
local Loading = require('vv-utils.loading')

local PROMPT_HEIGHT = 2
local LABEL_ROW = 0          -- 0-indexed：label overlay 行
local INPUT_ROW = 1          -- 0-indexed：用户输入行
local INPUT_LNUM = INPUT_ROW + 1  -- nvim_win_set_cursor 是 1-indexed

local M = {}

hl.register('vv-utils.prompt.hl', {
  VVPromptIcon  = { link = 'Special' },
  VVPromptLabel = { link = 'Title' },
  VVPromptHint  = { link = 'Comment' },
  VVPromptCount = { link = 'Comment' },
})

-- 创建浮窗 buffer + window，贴在 anchor 窗口底部 PROMPT_HEIGHT 行
---@param anchor_win integer
---@param initial string
---@param filetype? string
---@return integer? buf, integer? win
local function setup_floating_window(anchor_win, initial, filetype)
  if not vim.api.nvim_win_is_valid(anchor_win) then return nil, nil end

  local pos = vim.api.nvim_win_get_position(anchor_win)
  local width = vim.api.nvim_win_get_width(anchor_win)
  local height = vim.api.nvim_win_get_height(anchor_win)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  if filetype then vim.bo[buf].filetype = filetype end
  -- 两行：line 0 占位给 label overlay，line 1 是用户输入
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '', initial })

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = pos[1] + height - PROMPT_HEIGHT,
    col = pos[2],
    width = width,
    height = PROMPT_HEIGHT,
    style = 'minimal',
    border = 'none',
    focusable = true,
    zindex = 50,
  })

  local api = vim.api
  api.nvim_set_option_value('winhighlight', 'Normal:NormalFloat', { win = win, scope = 'local' })
  api.nvim_set_option_value('signcolumn', 'no', { win = win, scope = 'local' })
  api.nvim_set_option_value('number', false, { win = win, scope = 'local' })
  api.nvim_set_option_value('cursorline', false, { win = win, scope = 'local' })
  return buf, win
end

-- 装饰：label overlay 在 line 0；placeholder overlay 在 line 1。返回 redraw()
-- busy_ctx = { busy, label, frame_char } 由 spinner ticker 维护；
-- status 优先级：busy > opts.status_override > opts.get_status
---@param buf integer
---@param opts VVPromptOpts
---@param busy_ctx { busy: boolean, label: string, frame_char: string }
---@return fun() redraw
local function setup_decorations(buf, opts, busy_ctx)
  local label_ns = vim.api.nvim_create_namespace('vv-utils-prompt-label')
  local ph_ns = vim.api.nvim_create_namespace('vv-utils-prompt-ph')
  local icon = opts.icon or ''
  local label = opts.label or 'filter'
  local placeholder = opts.placeholder or 'type to filter…'

  local status_override = nil  -- set_status 推送的文案（非 busy 时覆盖 get_status）

  -- 有 get_mode → 画 mode badge（icon+label）+ <S-Tab> 提示；否则回退静态 label
  local function draw_label()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.api.nvim_buf_clear_namespace(buf, label_ns, 0, -1)

    local mode = opts.get_mode and opts.get_mode()
    local segs
    if mode then
      local md = (opts.mode_display and opts.mode_display(mode))
        or { icon = '', label = mode, hl = 'VVPromptLabel' }
      segs = {
        { ' ',                        'VVPromptHint' },
        { md.icon .. ' ' .. md.label, md.hl },
        { '  ',                       'VVPromptHint' },
        { '⇧Tab',                     'VVPromptIcon' },
        { ' switch',                  'VVPromptHint' },
      }
    else
      segs = {
        { ' ',          'VVPromptHint' },
        { icon .. ' ',  'VVPromptIcon' },
        { label,        'VVPromptLabel' },
      }
    end

    -- 状态：busy → spinner 帧 + busy 文案；否则 set_status 推送 > get_status 拉取
    local status
    if busy_ctx.busy then
      status = (busy_ctx.frame_char or '') .. ' ' .. (busy_ctx.label or '')
    elseif status_override ~= nil then
      status = status_override
    elseif opts.get_status then
      status = opts.get_status()
    end
    if status and status ~= '' then
      segs[#segs + 1] = { '  ·  ', 'VVPromptHint' }
      segs[#segs + 1] = { status, 'VVPromptCount' }
    end

    vim.api.nvim_buf_set_extmark(buf, label_ns, LABEL_ROW, 0, {
      virt_text = segs,
      virt_text_pos = 'overlay',
      right_gravity = false,
    })
  end

  local function draw_placeholder()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.api.nvim_buf_clear_namespace(buf, ph_ns, 0, -1)
    local line = vim.api.nvim_buf_get_lines(buf, INPUT_ROW, INPUT_ROW + 1, false)[1] or ''
    if #line == 0 then
      vim.api.nvim_buf_set_extmark(buf, ph_ns, INPUT_ROW, 0, {
        virt_text = { { placeholder, 'VVPromptHint' } },
        virt_text_pos = 'overlay',
        right_gravity = false,
      })
    end
  end

  local function redraw()
    draw_label()
    draw_placeholder()
  end
  -- set_status 推送文案的写入口（闭包共享 status_override）
  local function set_status_text(text) status_override = text end
  return redraw, set_status_text
end

-- 取消 / 提交 / 切模式 / 导航 / 分屏 keymap
---@param buf integer
---@param opts VVPromptOpts
---@param ctx { close: fun(), get_query: fun(): string, redraw: fun() }
local function setup_keymaps(buf, opts, ctx)
  local map = function(lhs, fn)
    vim.keymap.set({ 'i', 'n' }, lhs, fn, { buffer = buf, nowait = true, silent = true })
  end

  -- stopinsert 必须先于 close：否则 prompt 关后 Insert 模式残留，焦点回侧栏时按键写到落脚 buffer
  map('<Esc>', function()
    vim.cmd.stopinsert()
    ctx.close()
    opts.on_cancel()
  end)

  map('<CR>', function()
    local q = ctx.get_query()
    vim.cmd.stopinsert()
    ctx.close()
    opts.on_accept(q)
  end)

  -- normal 模式 q（可经 <C-c> 退到 normal 后使用）
  vim.keymap.set('n', 'q', function()
    vim.cmd.stopinsert()
    ctx.close()
    opts.on_cancel()
  end, { buffer = buf, nowait = true, silent = true })

  -- <S-Tab>：循环切换模式（焦点不离开输入框），切完立即重画 badge
  if opts.on_cycle_mode then
    map('<S-Tab>', function()
      opts.on_cycle_mode()
      ctx.redraw()
    end)
  end

  -- <C-n>/<C-p>：在宿主列表里跳下/上一个 match（焦点留在 prompt）
  if opts.on_navigate then
    map('<C-n>', function() opts.on_navigate(1) end)
    map('<C-p>', function() opts.on_navigate(-1) end)
  end

  -- <C-x>/<C-v>：以 split / vsplit 打开当前 match（先 stopinsert+close 再回调）
  if opts.on_open_in then
    local function open_then_close(kind)
      return function()
        vim.cmd.stopinsert()
        ctx.close()
        opts.on_open_in(kind)
      end
    end
    map('<C-x>', open_then_close('split'))
    map('<C-v>', open_then_close('vsplit'))
  end
end

-- 打开过滤输入框
---@param anchor_win integer        宿主侧栏 window id（浮窗贴它底部、宽度对齐）
---@param opts VVPromptOpts
---@return VVPromptHandle? handle    宿主应在自身销毁时调 handle.close() 连带关浮窗
function M.open(anchor_win, opts)
  local initial = opts.initial or ''
  local buf, win = setup_floating_window(anchor_win, initial, opts.filetype)
  if not buf or not win then return end

  local closed = false
  local cancel_debounce = nil
  local aug_name = 'vv-utils.prompt.' .. buf

  local busy_ctx = { busy = false, label = '', frame_char = '' }
  local ticker_stop = nil  -- vv-utils.loading.ticker 的 stop 句柄

  local redraw, set_status_text = setup_decorations(buf, opts, busy_ctx)
  redraw()

  local function get_query()
    return vim.api.nvim_buf_get_lines(buf, INPUT_ROW, INPUT_ROW + 1, false)[1] or ''
  end

  local function stop_spinner()
    if ticker_stop then ticker_stop(); ticker_stop = nil end
  end

  local function close()
    if closed then return end
    closed = true
    stop_spinner()
    if cancel_debounce then pcall(cancel_debounce) end
    pcall(vim.api.nvim_del_augroup_by_name, aug_name)
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  -- spinner 的 timer + 帧循环交给 vv-utils.loading.ticker；on_frame 把当前帧字符
  -- 塞进 busy_ctx 后重画（帧渲染在本模块的 line0 overlay 里，与 badge/状态拼成一条）
  local function start_spinner()
    if ticker_stop then return end
    ticker_stop = Loading.ticker({
      frames = opts.spinner and opts.spinner.frames,
      interval_ms = opts.spinner and opts.spinner.interval_ms,
      on_frame = function(char)
        if closed or not busy_ctx.busy then stop_spinner(); return end
        busy_ctx.frame_char = char
        redraw()
      end,
    })
  end

  -- 光标落在输入行行尾，进入 Insert
  vim.api.nvim_win_set_cursor(win, { INPUT_LNUM, #initial })
  vim.cmd.startinsert({ bang = true })

  local aug = vim.api.nvim_create_augroup(aug_name, { clear = true })

  -- 兜底：buffer 被任何路径 wipe（含绕过 close 的外部关闭）时走 close，释放 uv timer
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = aug, buffer = buf, once = true,
    callback = function() close() end,
  })

  -- 光标锁：离开输入行就拉回
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
    group = aug, buffer = buf,
    callback = function()
      if closed or not vim.api.nvim_win_is_valid(win) then return end
      local pos = vim.api.nvim_win_get_cursor(win)
      if pos[1] ~= INPUT_LNUM then
        pcall(vim.api.nvim_win_set_cursor, win, { INPUT_LNUM, pos[2] })
      end
    end,
  })

  -- 防抖：on_change 后 redraw（状态/匹配数依赖筛选结果，须在 on_change 之后刷新）
  local on_change_debounced
  on_change_debounced, cancel_debounce = require('vv-utils.timer').debounce(function()
    if closed or not vim.api.nvim_buf_is_valid(buf) then return end
    opts.on_change(get_query())
    redraw()
  end, opts.debounce or 30)

  vim.api.nvim_create_autocmd({ 'TextChangedI', 'TextChanged' }, {
    group = aug, buffer = buf,
    callback = function()
      if opts.on_input then opts.on_input(get_query()) end
      redraw()  -- 占位/label 立即刷新（首字符即覆盖 placeholder），过滤走防抖
      on_change_debounced()
    end,
  })

  setup_keymaps(buf, opts, { close = close, get_query = get_query, redraw = redraw })

  -- 失焦自动取消
  vim.api.nvim_create_autocmd({ 'BufLeave', 'WinLeave' }, {
    group = aug, buffer = buf, once = true,
    callback = function()
      if not closed then
        close()
        opts.on_cancel()
      end
    end,
  })

  ---@class VVPromptHandle
  ---@field close fun()                       幂等关闭浮窗
  ---@field redraw fun()                       强制重画 label/placeholder
  ---@field set_busy fun(busy: boolean, label?: string)  开/关 spinner（push 模型）
  ---@field set_status fun(text: string)       推送状态文案（非 busy 时覆盖 get_status）
  return {
    close = close,
    redraw = redraw,
    set_busy = function(busy, label)
      if closed then return end
      busy_ctx.busy = busy and true or false
      if label ~= nil then busy_ctx.label = label end
      if busy_ctx.busy then start_spinner() else stop_spinner() end
      redraw()
    end,
    set_status = function(text)
      if closed then return end
      set_status_text(text)
      redraw()
    end,
  }
end

---@class VVPromptSpinnerOpts
---@field frames?      string[]  spinner 帧 @default 盲文 10 帧
---@field interval_ms? integer   帧间隔 @default 80

---@class VVPromptOpts
---@field initial?       string                       初始查询 @default ''
---@field filetype?      string                       浮窗 buffer 的 filetype
---@field icon?          string                       静态 label 图标（无 get_mode 时用）@default ''
---@field label?         string                       静态 label 文案（无 get_mode 时用）@default 'filter'
---@field placeholder?   string                       空输入占位 @default 'type to filter…'
---@field mode_display?  fun(mode: string): {icon:string, label:string, hl:string}  mode badge 显示元数据（需 get_mode）
---@field get_mode?      fun(): string                当前模式键，驱动 mode badge；缺省则显示静态 label
---@field on_cycle_mode? fun()                        <S-Tab>：切下一模式（宿主负责轮换 + 重筛）
---@field get_status?    fun(): string                实时状态文案（如 '12 matches'），随每次输入刷新
---@field on_input?      fun(query: string)           每次按键即时回调（防抖前，宿主可据此 set_busy）
---@field on_change      fun(query: string)           防抖后每次输入变化（实时筛选）
---@field on_accept      fun(query: string)           <CR>：保留过滤态，关闭输入框
---@field on_cancel      fun()                        <Esc> / normal q / 失焦：取消过滤
---@field on_navigate?   fun(dir: integer)            <C-n>=+1 / <C-p>=-1：宿主列表里跳 match
---@field on_open_in?    fun(kind: 'split'|'vsplit')  <C-x> / <C-v>：分屏打开当前 match
---@field debounce?      integer|fun(): integer       防抖毫秒（支持自适应函数）@default 30
---@field spinner?       VVPromptSpinnerOpts          提供则启用 busy spinner（配合 handle.set_busy）
return M
