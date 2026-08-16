-- 目录统计：直接子项的同步浅扫，以及按 entry 粒度让出的递归扫描
--
-- 递归统计的成本与目录下的 inode 总数成正比，同步做必然卡死主线程
-- （实测 5 万文件约 0.9s，89 万文件约 34s）。这里用显式 DFS 栈保存 scandir
-- 句柄，每处理一个 entry 就检查一次预算，超预算立即让出到下一个事件循环，
-- 因此单片占用可控（默认 8ms），总耗时与同步版本相当
--
-- 边界：
--   • 不跟随 symlink，只按 scandir 返回的 entry type 决定是否递归，不会成环
--   • 不做任何过滤，统计的是磁盘真实占用，口径与 `du` 一致
--   • cancel 后不再调度下一片，也不触发 on_done

local uv = vim.uv

local M = {}

local DEFAULT_BUDGET_ENTRIES = 2000
local DEFAULT_BUDGET_MS = 8
local DEFAULT_MAX_ENTRIES = 500000
local DEFAULT_PROGRESS_INTERVAL_MS = 100

---@class VVFsDirShallow
---@field path string
---@field exists boolean
---@field readable boolean
---@field entries integer 直接子项总数
---@field dirs integer
---@field files integer
---@field links integer
---@field modified integer?

---@class VVFsDirScanOptions
---@field budget_entries? integer 单片最多处理的 entry 数 @default 2000
---@field budget_ms? integer 单片最长占用主线程的毫秒数 @default 8
---@field max_entries? integer entry 总数上限，达到后标记 truncated 并停止 @default 500000
---@field max_depth? integer 最大递归深度，nil 表示不限制 @default nil
---@field progress_interval_ms? integer 两次 on_progress 之间的最小间隔 @default 100
---@field on_progress? fun(result: VVFsDirScanResult) 扫描中的阶段性结果，永远在 done=false 时触发
---@field on_done? fun(result: VVFsDirScanResult) 正常结束（含 truncated）时触发一次；cancel 不触发

---@class VVFsDirScanResult
---@field path string
---@field exists boolean
---@field readable boolean
---@field files integer
---@field dirs integer
---@field links integer
---@field bytes integer 所有普通文件与 symlink 自身的字节数之和
---@field entries integer 已处理的 entry 总数
---@field truncated boolean 是否因 max_entries 提前停止
---@field done boolean
---@field elapsed_ms number

---@class VVFsDirScanHandle
---@field cancel fun() 停止扫描，幂等；取消后不再触发任何回调
---@field is_done fun(): boolean

-- scandir 在部分文件系统上不返回 entry type，此时退回 lstat（不跟随 symlink）
---@param path string
---@param entry_type string?
---@return string?
local function resolve_type(path, entry_type)
  if entry_type and entry_type ~= 'unknown' then return entry_type end
  local stat = uv.fs_lstat(path)
  return stat and stat.type or nil
end

---@param path string
---@return VVFsDirShallow
function M.shallow(path)
  path = vim.fs.normalize(path)

  local stat = uv.fs_stat(path)
  local modified = stat and stat.mtime
  local result = {
    path = path,
    exists = stat ~= nil,
    readable = false,
    entries = 0,
    dirs = 0,
    files = 0,
    links = 0,
    modified = type(modified) == 'table' and modified.sec or modified,
  }
  if not stat or stat.type ~= 'directory' then return result end

  local handle = uv.fs_scandir(path)
  if not handle then return result end
  result.readable = true

  while true do
    local name, entry_type = uv.fs_scandir_next(handle)
    if not name then break end

    result.entries = result.entries + 1
    local kind = resolve_type(path .. '/' .. name, entry_type)

    if kind == 'directory' then
      result.dirs = result.dirs + 1
    elseif kind == 'link' then
      result.links = result.links + 1
    else
      result.files = result.files + 1
    end
  end

  return result
end

-- 递归统计目录下的文件数与总字节数。首片和 on_done 都经由 vim.schedule 触发，
-- 调用方一定先拿到 handle 再收到回调，不会出现「还没拿到句柄就被回调」的竞态
---@param path string
---@param opts? VVFsDirScanOptions
---@return VVFsDirScanHandle
function M.scan(path, opts)
  opts = opts or {}
  path = vim.fs.normalize(path)

  local budget_entries = opts.budget_entries or DEFAULT_BUDGET_ENTRIES
  local budget_ms = opts.budget_ms or DEFAULT_BUDGET_MS
  local max_entries = opts.max_entries or DEFAULT_MAX_ENTRIES
  local max_depth = opts.max_depth
  local progress_interval_ms = opts.progress_interval_ms or DEFAULT_PROGRESS_INTERVAL_MS

  local started = uv.hrtime()
  local stat = uv.fs_stat(path)
  local root = stat and stat.type == 'directory' and uv.fs_scandir(path) or nil

  local result = {
    path = path,
    exists = stat ~= nil,
    readable = root ~= nil,
    files = 0,
    dirs = 0,
    links = 0,
    bytes = 0,
    entries = 0,
    truncated = false,
    done = false,
    elapsed_ms = 0,
  }

  local stack = root and { { path = path, depth = 0, handle = root } } or {}
  local cancelled = false
  local finished = false
  local last_progress = started
  local timer

  ---@return VVFsDirScanResult
  local function snapshot()
    local copy = {}

    for key, value in pairs(result) do copy[key] = value end
    copy.elapsed_ms = (uv.hrtime() - started) / 1e6
    return copy
  end

  local function stop_timer()
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    timer = nil
  end

  local function finish()
    if finished or cancelled then return end
    finished = true
    stop_timer()

    result.done = true
    result.elapsed_ms = (uv.hrtime() - started) / 1e6
    if opts.on_done then opts.on_done(snapshot()) end
  end

  local step

  -- 必须走 timer 而不是 vim.schedule 自递归：schedule 的队列在同一次事件循环批次里
  -- 被排空，新排入的回调会被立刻接着执行，分片就退化成忙循环，主线程一样卡死
  -- （实测 89 万文件的目录会连续占用主线程 5.9s）。timer 让出到下一次 loop 迭代，
  -- 中间的按键和重绘才有机会被处理
  local function schedule_next()
    timer = timer or uv.new_timer()
    if not timer then return finish() end
    timer:start(0, 0, vim.schedule_wrap(step))
  end

  step = function()
    if cancelled or finished then return end

    local slice_started = uv.hrtime()
    local processed = 0

    -- 每片至少推进一个 entry：预算被配成 0 时，光看预算会让每片处理 0 个 entry 而
    -- 永远调度下去，扫描既不结束也不前进
    while #stack > 0 and (processed == 0 or (
      processed < budget_entries
      and (uv.hrtime() - slice_started) / 1e6 < budget_ms
    )) do
      local top = stack[#stack]
      local name, entry_type = uv.fs_scandir_next(top.handle)

      if not name then
        stack[#stack] = nil
      else
        processed = processed + 1
        result.entries = result.entries + 1

        local full = top.path .. '/' .. name
        local kind = resolve_type(full, entry_type)

        if kind == 'directory' then
          result.dirs = result.dirs + 1

          if not max_depth or top.depth < max_depth then
            local handle = uv.fs_scandir(full)
            if handle then
              stack[#stack + 1] = { path = full, depth = top.depth + 1, handle = handle }
            end
          end
        else
          if kind == 'link' then
            result.links = result.links + 1
          else
            result.files = result.files + 1
          end
          local entry_stat = uv.fs_lstat(full)
          if entry_stat then result.bytes = result.bytes + entry_stat.size end
        end

        if result.entries >= max_entries then
          result.truncated = true
          stack = {}
        end
      end
    end

    if #stack == 0 then return finish() end

    -- 回调可能同步取消（例如面板在进度回调里被关闭），必须在调度下一片前重新确认
    if opts.on_progress and (uv.hrtime() - last_progress) / 1e6 >= progress_interval_ms then
      last_progress = uv.hrtime()
      opts.on_progress(snapshot())
    end

    if cancelled then return end

    schedule_next()
  end

  -- 路径不可读时 stack 为空，step 会立刻走到 finish，调用方仍从 on_done 拿到
  -- readable=false 的结果，不需要为「不是目录」单独准备一条错误通道
  schedule_next()

  return {
    cancel = function()
      if finished then return end
      cancelled = true
      stack = {}
      stop_timer()
    end,
    is_done = function() return finished end,
  }
end

return M
