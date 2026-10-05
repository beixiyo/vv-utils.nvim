-- 远程会话检测：当前 nvim 是否正被远程（SSH / mosh）驱动，tmux 内外通用
--
-- 判据与 shell 侧实现 ~/.local/bin/remote-session 保持一致（本插件需自包含，不调用该脚本）；
-- 一致性测试：~/.zsh/tests/remote-session.test.sh（模拟远程进程链，同时跑两边实现）
--   1. 在 tmux 内且有在连 client：逐个 client 看进程祖先链
--      能识别「本机起的 tmux 被 SSH attach 复用」：此时 pane 环境里的 SSH_* 是 tmux 启动时的陈旧快照，不采信
--   2. 否则（不在 tmux / 没有 client）：nvim 自身的进程祖先链
--      环境变量可能被 sudo -i、env -i、后台服务清掉或伪造，进程链更可靠
--   3. 再否则看环境变量：SSH_CONNECTION（排除两端都是回环地址）/ SSH_TTY
--      兜住进程链看不到的情况（如 mosh-server 已脱离 sshd）
--   ps 失败（不存在 / 非零退出 / 被信号终止 / 超时）= 进程链信息不可用：tmux 判定视为“判不出”（tmux_clients 返回 nil），
--   is_remote 跳过第 2 步直接按环境变量兜底
--   进程祖先链（含自身，最多 25 层）任一进程名以 sshd 或 mosh-server 开头 → 远程
--
-- 机制与策略分开：tmux_clients 只给出逐 client 的 remote / local 分类，「任一 / 全部」由调用方决定；
-- is_remote 是“任一 client 来自远程即远程，判不出时依次看自身进程链、环境变量”这一种策略
--
-- 副作用：执行 `tmux list-clients`（仅在 tmux 内）与 `ps -A`，一次判定里各最多一次、各带超时
-- （tmux 分支与自身进程链共用同一份进程表）。同步版通常阻塞数十 ms；最坏情况下单条命令阻塞约
-- 2 × TIMEOUT_MS（约 1s：SystemObj:wait 先等 500ms，超时发 SIGKILL 后再等至多 500ms），
-- 一次判定两条命令合计约 2s。wait 在 SIGKILL 后仍可能拿不到结果（返回 nil），按命令失败处理
-- is_remote_async 不阻塞主循环、回调回到主循环；共用同一套判定，只是命令执行方式不同：单条命令超过
-- TIMEOUT_MS 即发 SIGKILL 并按失败处理（不等进程退出），一次判定两条命令合计最多约 1s。结果不缓存

local M = {}

local MAX_DEPTH = 25
local TIMEOUT_MS = 500

--- 命令是否正常结束：退出码 0 且未被信号终止
--- 外部 SIGTERM 杀掉子进程时 vim.system 给出 code 0、signal 15（vim.SystemCompleted.signal：
--- 正常退出为 0），stdout 不完整；shell 侧 $(ps …) 此时得到 143 按失败处理，这里保持一致
--- signal 为 nil（非 runtime 产生的结果）视同 0
---@param out vim.SystemCompleted?
---@return boolean
local function succeeded(out)
  return out ~= nil and out.code == 0 and (out.signal or 0) == 0
end

--- 同步执行器
--- wait 超时会发 SIGKILL 再等一次，仍可能返回 nil（nvim runtime vim/_core/system.lua 的已知 TODO），按失败处理
---@type VVRemoteRunner
local function run_sync(cmd)
  local ok, proc = pcall(vim.system, cmd, { text = true })
  if not ok then return nil end
  local out = proc:wait(TIMEOUT_MS)
  if not succeeded(out) then return nil end
  return out.stdout
end

--- 启动 / 恢复 is_remote_async 的协程，检查 resume 结果
--- 协程常在 vim.system 回调里恢复，resume 的失败返回值若被丢弃，callback 或 detect 的错误会被静默吞掉、
--- 调用方等不到 callback 也无从得知；这里以 ERROR 级 vim.notify 报告（与 loading.handle 渲染失败的处理一致）
--- 不重新抛出：恢复点在 vim.schedule 回调里，抛出只会变成一条无上下文的事件循环错误
---@param co thread
---@param ... any 传给 coroutine.resume
local function resume(co, ...)
  local ok, err = coroutine.resume(co, ...)
  if not ok then
    vim.notify('vv-utils.sys.remote: is_remote_async failed: ' .. debug.traceback(co, tostring(err)), vim.log.levels.ERROR)
  end
end

--- 在下一轮主循环调用 is_remote_async 的 callback，抛错时按与 resume 相同的方式报告
--- 统一延后：ps / tmux 不存在时 vim.system 同步抛错，detect 不会挂起，若直接调用 callback
--- 就会在 is_remote_async 返回前同步执行，与正常路径的异步时序不一致
---@param callback fun(remote: boolean)
---@param remote boolean
local function deliver(callback, remote)
  vim.schedule(function()
    local ok, err = xpcall(callback, debug.traceback, remote)
    if not ok then
      vim.notify('vv-utils.sys.remote: is_remote_async failed: ' .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

--- 协程执行器：必须在协程内调用，挂起直到命令结束或超时；恢复点经 vim.schedule 回到主循环
--- 不用 vim.system 的 timeout 选项：它超时只发 SIGTERM，进程忽略 TERM 时要等其自行退出（挂死则永不恢复）
--- 改为自建 timer：TIMEOUT_MS 后直接 SIGKILL 并以 nil（失败）恢复协程，总时长上限 TIMEOUT_MS
--- exit 回调与 timer 回调都在 luv 回调（fast event）里执行，只做 uv 操作，由 done 保证只恢复一次
--- vim.system 抛错时本函数直接返回 nil、协程同步继续执行：此后迟到的 exit 回调不得再关 timer，
--- 已排队的恢复也必须作废（abandoned），否则会 resume 已在别处挂起或已结束的协程
---@type VVRemoteRunner
local function run_async(cmd)
  local co = coroutine.running()
  local timer = assert(vim.uv.new_timer())
  local done = false
  local abandoned = false

  --- 只生效一次：释放 timer，在主循环恢复协程
  ---@param stdout string?
  local function finish(stdout)
    if done then return end
    done = true
    timer:stop()
    timer:close()
    vim.schedule(function()
      if not abandoned then resume(co, stdout) end
    end)
  end

  local ok, proc = pcall(vim.system, cmd, { text = true }, function(out)
    finish(succeeded(out) and out.stdout or nil)
  end)
  if not ok then
    abandoned = true
    -- spawn 成功后才抛错时 exit 回调可能已执行 finish（timer 已关闭）
    if not done then
      done = true
      timer:close()
    end
    return nil
  end

  timer:start(TIMEOUT_MS, 0, function()
    if done then return end
    -- 进程可能刚退出、句柄已关闭而 exit 回调尚未执行，kill 失败无妨
    pcall(proc.kill, proc, 'sigkill')
    finish(nil)
  end)
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
---@param target string? 只列连在该 session / pane 所属 session 上的客户端
---@return integer[]?
local function tmux_client_pids(run, target)
  local tmux = vim.env.TMUX
  if not tmux or tmux == '' then return nil end

  -- $TMUX = "<socket>,<server pid>,<session id>"：用同一 socket，避免连到别的 tmux 服务器
  local socket = tmux:match('^([^,]+)')
  local cmd = { 'tmux', '-S', socket, 'list-clients' }
  if target and target ~= '' then vim.list_extend(cmd, { '-t', target }) end
  vim.list_extend(cmd, { '-F', '#{client_pid}' })
  local stdout = run(cmd)
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
---@return VVRemoteProcs? ps 失败（不存在 / 非零退出 / 被信号终止 / 超时 / 无输出）返回 nil
local function process_table(run)
  local stdout = run({ 'ps', '-A', '-o', 'pid=', '-o', 'ppid=', '-o', 'comm=' })
  if not stdout then return nil end

  local procs, n = {}, 0
  for line in stdout:gmatch('[^\n]+') do
    local pid, ppid, comm = line:match('^%s*(%d+)%s+(%d+)%s+(.-)%s*$')
    if pid then
      procs[tonumber(pid)] = { ppid = tonumber(ppid), comm = comm }
      n = n + 1
    end
  end
  return n > 0 and procs or nil
end

--- 惰性进程表：首次调用才执行 ps，之后（含失败结果）复用，保证一次判定里 ps 最多一次
---@param run VVRemoteRunner
---@return fun(): VVRemoteProcs?
local function lazy_process_table(run)
  local loaded, procs = false, nil
  return function()
    if not loaded then
      loaded = true
      procs = process_table(run)
    end
    return procs
  end
end

--- 进程祖先链（含自身）是否出现 sshd* / mosh-server*
--- 进程名取 comm 第一个词、去掉结尾冒号再取 basename（与 remote-session 相同）：
--- macOS 的 comm 是完整路径（/usr/sbin/sshd → sshd）；OpenSSH 9.8+ 改写的进程名
--- "sshd-session: es@ttys010" → sshd-session
---@param procs VVRemoteProcs
---@param pid integer
---@return boolean
local function remote_chain(procs, pid)
  for _ = 1, MAX_DEPTH do
    local p = procs[pid]
    if not p then return false end
    local name = (p.comm:match('^%S+') or ''):gsub(':$', '')
    name = name:match('[^/]+$') or name
    if vim.startswith(name, 'sshd') or vim.startswith(name, 'mosh-server') then return true end
    if p.ppid <= 1 then return false end
    pid = p.ppid
  end
  return false
end

--- 环境变量兜底：进程链看不出远程时
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

--- 逐 client 分类；不在 tmux / 没有 client / 查询失败 / ps 失败返回 nil（调用方自行兜底）
---@param run VVRemoteRunner
---@param get_procs fun(): VVRemoteProcs? 进程表来源（lazy_process_table），便于与自身进程链共用
---@param target string?
---@return VVRemoteClient[]?
local function classify(run, get_procs, target)
  local pids = tmux_client_pids(run, target)
  if not pids or #pids == 0 then return nil end
  local procs = get_procs()
  if not procs then return nil end

  local clients = {}
  for _, pid in ipairs(pids) do
    clients[#clients + 1] = { pid = pid, remote = remote_chain(procs, pid) }
  end
  return clients
end

--- 策略：任一 client 来自远程即远程；tmux 判不出时依次看 nvim 自身进程链、环境变量
--- 进程表只取一次：ps 失败时 tmux 分支与自身进程链都不可用，直接按环境变量兜底
---@param run VVRemoteRunner
---@return boolean
local function detect(run)
  local get_procs = lazy_process_table(run)
  local clients = classify(run, get_procs)
  if clients then
    for _, c in ipairs(clients) do
      if c.remote then return true end
    end
    return false
  end

  local procs = get_procs()
  if procs and remote_chain(procs, vim.uv.os_getpid()) then return true end
  return env_says_remote()
end

--- 在连 tmux 客户端逐个判定是否经远程（SSH / mosh）连入（机制，不含策略）
--- 不在 tmux / 没有 client / 查询失败 / ps 失败返回 nil。同步执行外部命令，结果不缓存
---@param opts? { target?: string } target：只看连在该 session（可传 pane id）上的客户端；默认整个 server
---@return VVRemoteClient[]?
function M.tmux_clients(opts)
  return classify(run_sync, lazy_process_table(run_sync), opts and opts.target)
end

--- 当前 nvim 是否正被远程驱动（含本机 tmux 被 SSH / mosh attach 的情形；不在 tmux 时同样可用）
--- 同步执行外部命令（会阻塞数十 ms），结果不缓存：tmux 客户端随时可能 attach / detach
---@return boolean
function M.is_remote()
  return detect(run_sync)
end

--- is_remote 的异步版本：不阻塞主循环，callback 始终在 is_remote_async 返回之后、于主循环中调用
--- 需在主循环调用（内部读取 vim.env，不能在 fast event / luv 回调里直接调用）
--- detect 或 callback 抛错时以 ERROR 级 vim.notify 报告（不静默吞掉）；detect 抛错时 callback 不会被调用
---@param callback fun(remote: boolean)
function M.is_remote_async(callback)
  resume(coroutine.create(function()
    deliver(callback, detect(run_async))
  end))
end

---@alias VVRemoteRunner fun(cmd: string[]): string?  执行命令返回 stdout；失败（不存在 / 非零退出 / 被信号终止 / 超时 / 无结果）返回 nil

---@alias VVRemoteProcs table<integer, { ppid: integer, comm: string }> pid → 父 pid 与进程名

---@class VVRemoteClient
---@field pid integer tmux 客户端进程 pid
---@field remote boolean 进程祖先链含 sshd / mosh-server（经远程连入）

return M
