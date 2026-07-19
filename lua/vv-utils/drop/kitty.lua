-- Kitty OSC 72 DnD 协议：探测、事件解析与 URI 数据拉取

local M = {}

local OSC = '\27]'
local ST = '\27\\'

-- 写转义序列到宿主终端（nvim 自带 osc52 clipboard provider 同款做法）
local function tsend(sequence)
  pcall(vim.api.nvim_ui_send, sequence)
end

-- 落点数据的拉取状态：drop（t=M）后置位，分块响应（t=r）累积，末块解码后清空
---@type { x:integer, y:integer, op:integer, chunks:string[] }?
local pending

-- 解析 metadata 段（冒号分隔的 k=v）："t=m:x=3:y=5:o=3" → { t='m', x='3', ... }
local function parse_meta(meta)
  local key_values = {}
  for pair in meta:gmatch('[^:]+') do
    local key, value = pair:match('^(%w+)=(.*)$')
    if key then key_values[key] = value end
  end
  return key_values
end

-- kitty 发的 base64 省略了尾部 '=' 填充，而 vim.base64.decode 严格要求填充长度为 4 的倍数，
-- 不补会对「长度非 4 倍数」的 payload（文件夹 / 多文件 / 多数路径）直接解码失败。按余数补 '='。
local function b64_decode(value)
  local remainder = #value % 4
  if remainder == 2 then value = value .. '=='
  elseif remainder == 3 then value = value .. '=' end
  return vim.base64.decode(value)
end

-- text/uri-list（base64 解码后）→ 本地绝对路径列表。
-- file:// URI 已百分号编码（无字面空白），故按空白切分可同时兼容 RFC 的 CRLF 分隔与空格分隔；
-- '#' 注释行 / 非绝对路径自然被跳过。每个路径 normalize 去尾斜杠——kitty 规定目录 URI 必带 '/'，
-- 不去掉会让 vim.fs.basename 取空、目标名算错（文件夹复制错位的根因）。
local function uri_list_to_paths(text)
  local paths = {}
  for uri in text:gmatch('%S+') do
    local path
    if uri:match('^file://') then
      local ok, filename = pcall(vim.uri_to_fname, uri)
      if ok then path = filename end
    elseif uri:match('^/') then
      path = uri
    end
    if path then paths[#paths + 1] = vim.fs.normalize(path) end
  end
  return paths
end

-- TermResponse 回调：解析 kitty 发来的 OSC 72 事件
---@param sequence string
---@param dispatch fun(paths: string[], pos: vv-utils.drop.Position?): boolean
---@param fire_drag fun(event: vv-utils.drop.DragEvent)
local function on_osc72(sequence, dispatch, fire_drag)
  local body = sequence:match('\27%]72;(.*)')
  if not body then return end
  body = body:gsub('\27\\$', ''):gsub('\7$', '') -- 去掉可能残留的 ST / BEL

  local meta, payload = body:match('^(.-);(.*)$')
  if not meta then meta, payload = body, nil end

  local key_values = parse_meta(meta)
  local event_type = key_values.t

  if event_type == 'q' then
    -- 支持探测的回应 → opt-in：声明接受 text/uri-list 拖拽
    tsend(OSC .. '72;t=a;text/uri-list' .. ST)

  elseif event_type == 'm' then
    if key_values.x == '-1' or key_values.y == '-1' then
      fire_drag({ kind = 'leave' })
    else
      -- 握手：告诉终端「接受（copy）」，否则 OS 视为不接受、drop 不会触发
      tsend(OSC .. '72;t=m:o=1;text/uri-list' .. ST)
      fire_drag({
        kind = 'move',
        x = tonumber(key_values.x),
        y = tonumber(key_values.y),
        op = tonumber(key_values.o),
      })
    end

  elseif event_type == 'M' then
    fire_drag({ kind = 'leave' }) -- 落点确定，先清高亮
    pending = {
      x = tonumber(key_values.x),
      y = tonumber(key_values.y),
      op = tonumber(key_values.o),
      chunks = {},
    }
    tsend(OSC .. '72;t=r:x=1' .. ST) -- 请求第 1 个 MIME（text/uri-list）的数据

  elseif event_type == 'r' then
    local current = pending
    if not current then return end
    if payload and payload ~= '' then current.chunks[#current.chunks + 1] = payload end
    if key_values.m ~= '1' then -- 末块（m=0 或缺省）；m=1 表示还有后续分块
      pending = nil
      local ok, decoded = pcall(b64_decode, table.concat(current.chunks))
      if not ok or not decoded then return end
      local paths = uri_list_to_paths(decoded)
      if #paths > 0 then
        dispatch(paths, { x = current.x, y = current.y, op = current.op })
      end
    end
  end
end

local kitty_autocmd

---@param dispatch fun(paths: string[], pos: vv-utils.drop.Position?): boolean
---@param fire_drag fun(event: vv-utils.drop.DragEvent)
function M.setup(dispatch, fire_drag)
  if kitty_autocmd then return end
  kitty_autocmd = vim.api.nvim_create_autocmd('TermResponse', {
    -- pcall 兜底：单条畸形序列（坏 URI / 异常 payload）不应炸掉整个拖拽处理
    callback = function(event)
      pcall(on_osc72, event.data.sequence, dispatch, fire_drag)
    end,
  })
  -- 探测支持；opt-in 在收到 t=q 回应后进行。不支持的终端（含 tmux 内）无回应 → 静默回退
  tsend(OSC .. '72;t=q' .. ST)
end

return M
