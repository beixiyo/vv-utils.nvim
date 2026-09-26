-- 远程会话检测：当前 nvim 是否正被 SSH 远程驱动
--
-- 判据（与 ~/.zsh/notify/tmux.sh 的 _is_remote_session 对齐）：
--   1. 在 tmux 内：任一在连 tmux 客户端的进程祖先链含 sshd → 远程
--      能识别「本机起的 tmux 被 SSH attach 复用」：此时 pane 环境里没有 SSH_CONNECTION
--      （tmux 服务器是本地起的，环境被冻结），只有客户端进程祖先链才暴露远程身份
--      有在连客户端且都不在 sshd 之下 → 本地；环境里残留的 SSH_* 是 tmux 启动时的历史，不采信
--   2. 否则看环境变量：SSH_CONNECTION（排除两端都是回环地址）/ SSH_TTY
--
-- 副作用：执行 `tmux list-clients` 与 `ps -A`（各一次，带超时）。is_remote 同步阻塞约数十 ms，
-- is_remote_async 在后台跑、回调回到主循环；两者共用同一套判定，只是命令执行方式不同。结果不缓存

local M = {}

local MAX_DEPTH = 25
local TIMEOUT_MS = 500

---@alias VVRemoteRunner fun(cmd: string[]): string?  执行命令返回 stdout；失败（不存在 / 非零退出 / 超时）返回 nil

--- 同步执行器
---@type VVRemoteRunner
local function run_sync(cmd)
  local ok, proc = pcall(vim.system, cmd, { text = true })
  if not ok then return nil end
  local out = proc:wait(TIMEOUT_MS)
  if out.code ~= 0 then return nil end
  return out.stdout
end

--- 协程执行器：必须在协程内调用，挂起直到命令结束；恢复点经 vim.schedule 回到主循环
---@type VVRemoteRunner
local function run_async(cmd)
  local co = coroutine.running()
  local ok = pcall(vim.system, cmd, { text = true, timeout = TIMEOUT_MS }, function(out)
    vim.schedule(function()
      coroutine.resume(co, out.code == 0 and out.stdout or nil)
    end)
  end)
  if not ok then return nil end
  return coroutine.yield()
end

---@param host string
---@return boolean
local function is_loopback(host)
  host = host:lower()
  return host == 'localhost' or host == '::1' or vim.startswith(host, '127.')
end

--- 在连 tmux 客户端的 pid；不在 tmux 内或查询失败返回 nil
---@param run VVRemoteRunner
---@return integer[]?
local function tmux_client_pids(run)
  local tmux = vim.env.TMUX
  if not tmux or tmux == '' then return nil end

  -- $TMUX = "<socket>,<server pid>,<session id>"：用同一 socket，避免连到别的 tmux 服务器
  local socket = tmux:match('^([^,]+)')
  local stdout = run({ 'tmux', '-S', socket, 'list-clients', '-F', '#{client_pid}' })
  if not stdout then return nil end

  local pids = {}
  for line in stdout:gmatch('[^\n]+') do
    local pid = tonumber(vim.trim(line))
    if pid then pids[#pids + 1] = pid end
  end
  return pids
end

--- 全量进程表 pid → { ppid, comm }；一次 ps 调用，祖先链在内存里走
---@param run VVRemoteRunner
---@return table<integer, { ppid: integer, comm: string }>?
local function process_table(run)
  local stdout = run({ 'ps', '-A', '-o', 'pid=', '-o', 'ppid=', '-o', 'comm=' })
  if not stdout then return nil end

  local procs = {}
  for line in stdout:gmatch('[^\n]+') do
    local pid, ppid, comm = line:match('^%s*(%d+)%s+(%d+)%s+(.-)%s*$')
    if pid then procs[tonumber(pid)] = { ppid = tonumber(ppid), comm = comm } end
  end
  return procs
end

--- 进程祖先链（含自身）是否出现 sshd*（macOS 的 comm 是完整路径，取 basename；
--- OpenSSH 9.8+ 的会话进程名为 sshd-session，同样命中）
---@param procs table<integer, { ppid: integer, comm: string }>
---@param pid integer
---@return boolean
local function under_sshd(procs, pid)
  for _ = 1, MAX_DEPTH do
    local p = procs[pid]
    if not p then return false end
    local name = p.comm:match('[^/]+$') or p.comm
    if vim.startswith(name, 'sshd') then return true end
    if p.ppid <= 1 then return false end
    pid = p.ppid
  end
  return false
end

--- 环境变量兜底：非 tmux 场景下 nvim 直接跑在 SSH shell 里
---@return boolean
local function env_says_remote()
  local conn = vim.env.SSH_CONNECTION
  if conn and conn ~= '' then
    local src, _, dst = unpack(vim.split(conn, '%s+', { trimempty = true }))
    if src and dst then
      return not (is_loopback(src) and is_loopback(dst))
    end
  end
  local tty = vim.env.SSH_TTY
  return tty ~= nil and tty ~= ''
end

---@param run VVRemoteRunner
---@return boolean
local function detect(run)
  local clients = tmux_client_pids(run)
  if clients and #clients > 0 then
    local procs = process_table(run)
    if procs then
      for _, pid in ipairs(clients) do
        if under_sshd(procs, pid) then return true end
      end
      return false
    end
  end
  return env_says_remote()
end

--- 当前 nvim 是否正被 SSH 远程驱动（含本机 tmux 被 SSH attach 的情形）
--- 同步执行外部命令（会阻塞数十 ms），结果不缓存：tmux 客户端随时可能 attach / detach
---@return boolean
function M.is_remote()
  return detect(run_sync)
end

--- is_remote 的异步版本：不阻塞主循环，callback 在主循环中调用
---@param callback fun(remote: boolean)
function M.is_remote_async(callback)
  coroutine.wrap(function()
    local remote = detect(run_async)
    callback(remote)
  end)()
end

return M
