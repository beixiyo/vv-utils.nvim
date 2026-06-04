-- kitty DnD 协议探针（只读，不碰任何文件）
--
-- 目的：在「kitty ≥ 0.47 且 nvim 不挂 tmux」环境下，验证 OSC 72 拖拽事件能否
--       进到 nvim、坐标对不对、能否拉到路径。确认后再写正式的 vv-explorer 落点功能。
--
-- 用法（务必在【不开 tmux】的 kitty 里）：
--   1. kitty 升级到 ≥ 0.47（kitty --version 确认）
--   2. 直接开 nvim（不要进 tmux）
--   3. :luafile /Users/es/.config/nvim/vendors/vv-utils.nvim/scratch/dnd_probe.lua
--   4. 从 Finder 拖一个文件/文件夹到这个 nvim 窗口里松手
--   5. :messages 看实时反馈；完整日志见 :lua print(require... ) 提示的路径
--   6. 把日志内容贴给我
--
-- 停止：:lua _G.__dnd_probe.stop()

local OSC, ST = '\27]', '\27\\'
local LOG = vim.fn.stdpath('cache') .. '/vv_dnd_probe.log'

local M = {}

local function log(msg)
  local f = io.open(LOG, 'a')
  if f then
    f:write(os.date('%H:%M:%S ') .. msg .. '\n')
    f:close()
  end
end

local function send(seq) vim.api.nvim_ui_send(seq) end

-- 解析 metadata 段："t=m:x=3:y=5:o=3" → { t='m', x='3', y='5', o='3' }
local function parse_meta(meta)
  local kv = {}
  for pair in meta:gmatch('[^:]+') do
    local k, v = pair:match('^(%w+)=(.*)$')
    if k then kv[k] = v end
  end
  -- 形如 "t=m" 的首段没有第二个 = 时上面也能命中（k=t, v=m）
  return kv
end

-- base64 累积缓冲（t=r 分块响应）
local data_chunks = {}
local move_count = 0

local function handle(seq)
  -- 取出 OSC 72 ; 之后的全部内容，去掉结尾 ST / BEL
  local body = seq:match('\27%]72;(.*)')
  if not body then return false end
  body = body:gsub('\27\\$', ''):gsub('\7$', '')

  -- 拆 meta;payload（payload 可缺省）
  local meta, payload = body:match('^(.-);(.*)$')
  if not meta then meta, payload = body, nil end

  local kv = parse_meta(meta)
  local t = kv.t

  log(('RAW %s'):format(vim.inspect(seq)))

  if t == 'q' then
    -- 支持探测的回应 → 终端确实支持 DnD 协议
    log('SUPPORT confirmed, payload=' .. tostring(payload))
    vim.schedule(function() vim.notify('[dnd] 终端支持 DnD 协议 ✓') end)

  elseif t == 'm' then
    -- 拖拽移动；x=y=-1 表示离开窗口
    if kv.x == '-1' and kv.y == '-1' then
      log('LEAVE')
    else
      move_count = move_count + 1
      log(('MOVE x=%s y=%s X=%s Y=%s o=%s'):format(
        tostring(kv.x), tostring(kv.y), tostring(kv.X), tostring(kv.Y), tostring(kv.o)))
      -- 关键握手：告诉终端「我接受（copy）」，否则 drop 不会触发
      send(OSC .. '72;t=m:o=1;text/uri-list' .. ST)
    end

  elseif t == 'M' then
    -- 落点！记录坐标，并请求第 1 个 MIME（应是 text/uri-list）的数据
    log(('DROP  x=%s y=%s  (MIME list=%s)'):format(
      tostring(kv.x), tostring(kv.y), tostring(payload)))
    vim.schedule(function()
      vim.notify(('[dnd] DROP @ cell x=%s y=%s'):format(tostring(kv.x), tostring(kv.y)))
    end)
    data_chunks = {}
    send(OSC .. '72;t=r:x=1' .. ST)

  elseif t == 'r' then
    -- 拉取数据的分块响应；空 payload + m=0 表示结束
    if payload and payload ~= '' then
      data_chunks[#data_chunks + 1] = payload
    end
    local done = (kv.m == '0') or (not payload) or (payload == '')
    if done then
      local b64 = table.concat(data_chunks)
      local rem = #b64 % 4 -- kitty 省略 '=' 填充，补齐再解
      if rem == 2 then b64 = b64 .. '==' elseif rem == 3 then b64 = b64 .. '=' end
      local ok, decoded = pcall(vim.base64.decode, b64)
      log('URI-LIST raw(base64 len=' .. #b64 .. ')')
      if ok then
        log('URI-LIST decoded:\n' .. decoded)
        vim.schedule(function() vim.notify('[dnd] 拿到路径:\n' .. decoded) end)
      else
        log('URI-LIST decode FAILED')
      end
    end
  else
    log('OTHER t=' .. tostring(t))
  end

  return true
end

function M.start()
  -- 环境提醒
  if vim.env.TMUX and vim.env.TMUX ~= '' then
    vim.notify('[dnd] 警告：你在 tmux 里，事件大概率收不到。请退出 tmux 直接跑 kitty', vim.log.levels.WARN)
  end

  pcall(os.remove, LOG)
  log('=== probe started, term=' .. tostring(vim.env.TERM) .. ' ===')

  M._au = vim.api.nvim_create_autocmd('TermResponse', {
    callback = function(ev) pcall(handle, ev.data.sequence) end,
  })

  -- 声明接受 text/uri-list 拖拽 + 探测支持
  send(OSC .. '72;t=a;text/uri-list' .. ST)
  send(OSC .. '72;t=q' .. ST)

  vim.notify('[dnd] 探针已启动。拖一个文件进来。日志: ' .. LOG)
end

function M.stop()
  if M._au then pcall(vim.api.nvim_del_autocmd, M._au); M._au = nil end
  send(OSC .. '72;t=A' .. ST) -- 停止接受拖拽
  log(('=== stopped, moves=%d ==='):format(move_count))
  vim.notify('[dnd] 探针已停止。move 事件数=' .. move_count .. '，日志: ' .. LOG)
end

_G.__dnd_probe = M
M.start()

return M
