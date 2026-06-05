-- 终端拖拽路径检测 + handler 分发
--
-- 两条进入路径，统一走 dispatch(paths, pos)：
--   1. bracketed paste（覆写 vim.paste）：拖入的文件以「粘贴文本」形式到达，无坐标。
--      pos = nil。tmux / 不支持 DnD 协议的终端走这条。
--   2. kitty DnD 协议（OSC 72，kitty ≥ 0.47）：拖入带落点 cell 坐标 + 拖拽移动事件流。
--      pos = { x, y, op }（屏幕 cell，原点左上）。需 nvim 直接跑在 kitty 下（不挂 tmux，
--      tmux 不透传入站 OSC）。启动时探测，支持才 opt-in；不支持自动回退路径 1。
--
-- handler 签名 fun(paths, pos) → 返回 true 表示已消费。pos 为 nil 时是无坐标的粘贴落点，
-- 由 handler 自行决定（如复制到光标目录）；pos 非 nil 时按落点坐标处理。
-- 另有 M.on_drag(cb) 订阅拖拽移动 / 离开事件，用于实时高亮落点（仅 DnD 协议下触发）。
--
-- 各终端拖拽行为（对 TUI 应用如 Neovim）：
--   Kitty (Linux/macOS)     原始解码路径（无 shell 转义），换行分隔多文件，bracketed paste
--                           OSC 72 DnD 协议（0.47.0+）带落点坐标，本模块已支持（需脱 tmux）
--   Ghostty (Linux/GTK4)    bracketed paste，shell-escaped 路径
--   Ghostty (macOS/AppKit)  insertText 击键输入，不走 bracketed paste —— 无法拦截
--   WezTerm                 可配 quote_dropped_files: None | SpacesOnly | Posix | Windows
--   Alacritty / iTerm2      shell-escaped 路径，bracketed paste
--
-- 参考：
--   vim.paste API        :help vim.paste()  |  https://neovim.io/doc/user/lua.html#vim.paste()
--   TermResponse         :help TermResponse （接收终端 OSC/DCS/APC 响应）
--   bracketed paste      :help bracketed-paste
--   Kitty DnD 协议       https://sw.kovidgoyal.net/kitty/dnd-protocol/
--   Neovim Discussion    https://github.com/neovim/neovim/discussions/33567

local M = {}

---@type (fun(paths: string[], pos: VVDropPos?): boolean?)[]
local handlers = {}
---@type (fun(ev: VVDragEvent): nil)[]
local drag_handlers = {}
local original_paste

local OSC, ST = '\27]', '\27\\'

-- 写转义序列到宿主终端（nvim 自带 osc52 clipboard provider 同款做法）
local function tsend(seq) pcall(vim.api.nvim_ui_send, seq) end

local function strip_quotes(s)
  if #s < 2 then return s end
  local f, l = s:sub(1, 1), s:sub(-1)
  if (f == '"' and l == '"') or (f == "'" and l == "'") then
    return s:sub(2, -2)
  end
  return s
end

local function shell_unescape(s)
  return (s:gsub('\\(.)', '%1'))
end

-- 把一个候选字符串规整成可 fs_stat 的绝对路径；非绝对路径返回 nil
---@param s string
---@return string?
local function normalize_candidate(s)
  if s:match('^file://') then
    s = vim.uri_to_fname(s)
  end
  if not s:match('^[/~]') then return nil end
  return (s:gsub('^~', vim.env.HOME or '~'))
end

---@param raw string
---@return string?
local function try_resolve_path(raw)
  raw = raw:gsub('^%s+', ''):gsub('%s+$', '')
  if raw == '' then return nil end

  -- 候选按优先级：
  --   1. 原始路径（Kitty 等原始解码终端，无 shell 转义，可含字面反斜杠）
  --   2. strip_quotes + shell_unescape 后备（Ghostty/Alacritty 等 shell-转义终端）
  -- 逐个 fs_stat，返回首个真实存在的，避免把合法的字面反斜杠误 strip 成错误路径
  local candidates = { raw }

  local unescaped = shell_unescape(strip_quotes(raw))
  if unescaped ~= raw then
    candidates[#candidates + 1] = unescaped
  end

  for _, cand in ipairs(candidates) do
    local expanded = normalize_candidate(cand)
    if expanded then
      local stat = vim.uv.fs_stat(expanded)
      if stat then return expanded end
    end
  end

  return nil
end

--- 检测粘贴内容中的文件/目录路径（绝对路径，/ 或 ~ 开头）
--- 所有行都必须是合法路径才返回，任一行不是则返回 nil
---@param lines string[]
---@return string[]?
function M.detect_paths(lines)
  local joined = table.concat(lines, '\n')
  joined = joined:gsub('^%s+', ''):gsub('%s+$', '')
  if joined == '' then return nil end

  local candidates = vim.split(joined, '\n', { trimempty = true })
  if #candidates == 0 then return nil end

  local paths = {}
  for _, raw in ipairs(candidates) do
    local p = try_resolve_path(raw)
    if not p then return nil end
    paths[#paths + 1] = p
  end

  return #paths > 0 and paths or nil
end

--- 注册拖拽处理器，返回 true 表示已消费，阻止后续 handler
---@param handler fun(paths: string[], pos: VVDropPos?): boolean?
function M.register(handler)
  handlers[#handlers + 1] = handler
end

--- 订阅拖拽移动 / 离开事件（仅 kitty DnD 协议下触发），用于实时高亮落点
---@param handler fun(ev: VVDragEvent): nil
function M.on_drag(handler)
  drag_handlers[#drag_handlers + 1] = handler
end

local function fire_drag(ev)
  for _, h in ipairs(drag_handlers) do pcall(h, ev) end
end

--- 默认 handler：Normal 模式 + 普通 buffer 下打开文件
---@param paths string[]
---@return boolean
local function default_handler(paths)
  local mode = vim.fn.mode()
  if mode ~= 'n' and mode ~= 'nt' then return false end
  if vim.bo.buftype ~= '' then return false end

  for _, p in ipairs(paths) do
    local stat = vim.uv.fs_stat(p)
    if not stat or stat.type ~= 'file' then return false end
  end

  vim.schedule(function()
    for _, path in ipairs(paths) do
      vim.cmd('edit ' .. vim.fn.fnameescape(path))
    end
  end)
  return true
end

--- 统一分发：先过注册的 handler，都没消费则走默认（打开文件）
---@param paths string[]
---@param pos VVDropPos?
local function dispatch(paths, pos)
  for _, handler in ipairs(handlers) do
    if handler(paths, pos) then return true end
  end
  return default_handler(paths)
end

-- ── kitty DnD 协议（OSC 72）──

-- 落点数据的拉取状态：drop（t=M）后置位，分块响应（t=r）累积，末块解码后清空
---@type { x:integer, y:integer, op:integer, chunks:string[] }?
local pending

-- 解析 metadata 段（冒号分隔的 k=v）："t=m:x=3:y=5:o=3" → { t='m', x='3', ... }
local function parse_meta(meta)
  local kv = {}
  for pair in meta:gmatch('[^:]+') do
    local k, v = pair:match('^(%w+)=(.*)$')
    if k then kv[k] = v end
  end
  return kv
end

-- kitty 发的 base64 省略了尾部 '=' 填充，而 vim.base64.decode 严格要求填充长度为 4 的倍数，
-- 不补会对「长度非 4 倍数」的 payload（文件夹 / 多文件 / 多数路径）直接解码失败。按余数补 '='。
local function b64_decode(s)
  local rem = #s % 4
  if rem == 2 then s = s .. '=='
  elseif rem == 3 then s = s .. '=' end
  return vim.base64.decode(s)
end

-- text/uri-list（base64 解码后）→ 本地绝对路径列表。
-- file:// URI 已百分号编码（无字面空白），故按空白切分可同时兼容 RFC 的 CRLF 分隔与空格分隔；
-- '#' 注释行 / 非绝对路径自然被跳过。每个路径 normalize 去尾斜杠——kitty 规定目录 URI 必带 '/'，
-- 不去掉会让 vim.fs.basename 取空、目标名算错（文件夹复制错位的根因）。
local function uri_list_to_paths(text)
  local paths = {}
  for uri in text:gmatch('%S+') do
    local p
    if uri:match('^file://') then
      local ok, fn = pcall(vim.uri_to_fname, uri)
      if ok then p = fn end
    elseif uri:match('^/') then
      p = uri
    end
    if p then paths[#paths + 1] = vim.fs.normalize(p) end
  end
  return paths
end

-- TermResponse 回调：解析 kitty 发来的 OSC 72 事件
---@param seq string
local function on_osc72(seq)
  local body = seq:match('\27%]72;(.*)')
  if not body then return end
  body = body:gsub('\27\\$', ''):gsub('\7$', '') -- 去掉可能残留的 ST / BEL

  local meta, payload = body:match('^(.-);(.*)$')
  if not meta then meta, payload = body, nil end

  local kv = parse_meta(meta)
  local t = kv.t

  if t == 'q' then
    -- 支持探测的回应 → opt-in：声明接受 text/uri-list 拖拽
    tsend(OSC .. '72;t=a;text/uri-list' .. ST)

  elseif t == 'm' then
    if kv.x == '-1' or kv.y == '-1' then
      fire_drag({ kind = 'leave' })
    else
      -- 握手：告诉终端「接受（copy）」，否则 OS 视为不接受、drop 不会触发
      tsend(OSC .. '72;t=m:o=1;text/uri-list' .. ST)
      fire_drag({ kind = 'move', x = tonumber(kv.x), y = tonumber(kv.y), op = tonumber(kv.o) })
    end

  elseif t == 'M' then
    fire_drag({ kind = 'leave' }) -- 落点确定，先清高亮
    pending = { x = tonumber(kv.x), y = tonumber(kv.y), op = tonumber(kv.o), chunks = {} }
    tsend(OSC .. '72;t=r:x=1' .. ST) -- 请求第 1 个 MIME（text/uri-list）的数据

  elseif t == 'r' then
    local p = pending
    if not p then return end
    if payload and payload ~= '' then p.chunks[#p.chunks + 1] = payload end
    if kv.m ~= '1' then -- 末块（m=0 或缺省）；m=1 表示还有后续分块
      pending = nil
      local ok, decoded = pcall(b64_decode, table.concat(p.chunks))
      if not ok or not decoded then return end
      local paths = uri_list_to_paths(decoded)
      if #paths > 0 then
        dispatch(paths, { x = p.x, y = p.y, op = p.op })
      end
    end
  end
end

local kitty_au
local function setup_kitty_dnd()
  if kitty_au then return end
  kitty_au = vim.api.nvim_create_autocmd('TermResponse', {
    -- pcall 兜底：单条畸形序列（坏 URI / 异常 payload）不应炸掉整个拖拽处理
    callback = function(ev) pcall(on_osc72, ev.data.sequence) end,
  })
  -- 探测支持；opt-in 在收到 t=q 回应后进行。不支持的终端（含 tmux 内）无回应 → 静默回退
  tsend(OSC .. '72;t=q' .. ST)
end

--- 安装 vim.paste 拦截 + kitty DnD 协议
---@param opts { kitty_dnd?: boolean }?  kitty_dnd=false 关闭 OSC 72 落点协议（仅留粘贴路径）
function M.setup(opts)
  opts = opts or {}

  if not original_paste then
    original_paste = vim.paste

    vim.paste = function(lines, phase)
      if phase ~= -1 then
        return original_paste(lines, phase)
      end

      local paths = M.detect_paths(lines)
      if not paths then
        return original_paste(lines, phase)
      end

      if dispatch(paths, nil) then return false end
      return original_paste(lines, phase)
    end
  end

  if opts.kitty_dnd ~= false then
    setup_kitty_dnd()
  end
end

---@class VVDropPos kitty DnD 落点（屏幕 cell，原点左上）
---@field x integer
---@field y integer
---@field op integer  允许的操作：1=copy 2=move 3=either

---@class VVDragEvent 拖拽过程事件
---@field kind 'move'|'leave'
---@field x integer?  kind='move' 时为当前 cell x
---@field y integer?  kind='move' 时为当前 cell y
---@field op integer?

return M
