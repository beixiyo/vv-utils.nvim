-- 分片异步递归删除：语义与 operations.delete 一致，但不独占主线程
--
-- 同步递归删除的耗时与 inode 数成正比，大目录会冻结 UI，期间 loading 帧也无法推进
-- 这里用显式 DFS 栈保存 scandir 句柄，每片按时间预算处理若干 entry 后经 uv timer 让出
-- （不用 vim.schedule 自递归，原因见 dir_scan.lua），中间的按键、重绘与动画得以执行
--
-- 边界（与 delete 相同）：
--   • 只删除 target 本身及其内容；lstat 判断类型，符号链接只删链接本身、绝不跟随
--   • 目标在入口绑定绝对路径；每片开始复验父路径与已扫描目录的身份，替换 / 移动后停止
--   • 使用路径型 libuv API；身份复验不是对外部进程在单个系统调用间改路径的原子隔离
--   • 目标不存在视为成功
--   • 首个失败（unlink / rmdir / scandir）立即停止并通过 on_done(false, err) 报告；已删除的部分不回滚
--   • cancel 后不再调度下一片、不触发 on_done；已删除的部分保留

local uv = vim.uv

local M = {}

local DEFAULT_BUDGET_MS = 8

---@param target string
---@param opts VVFsDeleteAsyncOptions
---@return VVFsDeleteAsyncHandle
function M.delete_async(target, opts)
  target = vim.fs.normalize(target)
  -- 空目标保留「不存在」语义，不能由 :p 扩成 cwd 后删掉当前目录
  if target ~= '' then target = vim.fs.normalize(vim.fn.fnamemodify(target, ':p')) end

  local parent = target ~= '' and vim.fs.dirname(target) or nil
  local real_parent = parent and uv.fs_realpath(parent)

  if real_parent then
    -- 只解析父路径，目标本身若为 symlink 仍必须删链接而非链接指向的内容
    target = target == parent and real_parent or vim.fs.joinpath(real_parent, vim.fs.basename(target))
  end

  local budget_ms = opts.budget_ms or DEFAULT_BUDGET_MS
  local on_done = opts.on_done

  local stack = {} ---@type { path: string, handle: uv.uv_fs_t, stat: uv.fs_stat.result }[]
  local ancestors = {} ---@type { path: string, stat: uv.fs_stat.result }[]
  local ancestor_error

  if real_parent then
    local directory = real_parent
    while directory do
      local stat, err = uv.fs_lstat(directory)
      if not stat or stat.type ~= 'directory' then
        ancestor_error = 'directory changed during delete: ' .. directory .. ' — ' .. tostring(err)
        break
      end
      ancestors[#ancestors + 1] = { path = directory, stat = stat }
      local next_directory = vim.fs.dirname(directory)
      if next_directory == directory then break end
      directory = next_directory
    end
  end

  local cancelled, finished = false, false
  local timer ---@type uv.uv_timer_t?

  local function stop_timer()
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    timer = nil
  end

  ---@param ok boolean
  ---@param err? string
  local function finish(ok, err)
    if finished or cancelled then return end
    finished = true
    stack = {}
    stop_timer()
    on_done(ok, err)
  end

  -- scandir handle 仍可指向被移走的旧目录，字符串路径却可能已指向另一棵树；让出后必须复验
  local function verify_directories()
    for _, directories in ipairs({ ancestors, stack }) do
      for _, entry in ipairs(directories) do
        local stat = uv.fs_lstat(entry.path)
        if not stat or stat.type ~= 'directory' or stat.dev ~= entry.stat.dev or stat.ino ~= entry.stat.ino then
          return 'directory changed during delete: ' .. entry.path
        end
      end
    end
  end

  --- 删除一个非目录 entry，或把目录压栈；返回错误信息表示失败
  ---@param path string
  ---@return string? err
  local function visit(path)
    local stat = uv.fs_lstat(path)
    if not stat then return nil end -- 已不存在
    if stat.type == 'directory' then
      local handle, scan_err = uv.fs_scandir(path)
      if not handle then return 'scandir failed: ' .. path .. ' — ' .. tostring(scan_err) end
      stack[#stack + 1] = { path = path, handle = handle, stat = stat }
      return nil
    end

    local ok, unlink_err = uv.fs_unlink(path)
    if not ok then return 'unlink failed: ' .. path .. ' — ' .. tostring(unlink_err) end
  end

  local step

  local function schedule_next()
    timer = timer or uv.new_timer()
    if not timer then return finish(false, 'could not create timer') end
    timer:start(0, 0, vim.schedule_wrap(step))
  end

  step = function()
    if cancelled or finished then return end
    local changed = verify_directories()
    if changed then return finish(false, changed) end
    local slice_started = uv.hrtime()
    local processed = 0

    -- 每片至少推进一个 entry，避免预算为 0 时空转
    while #stack > 0 and (processed == 0 or (uv.hrtime() - slice_started) / 1e6 < budget_ms) do
      processed = processed + 1
      local top = stack[#stack]
      local name = uv.fs_scandir_next(top.handle)
      if name then
        local err = visit(top.path .. '/' .. name)
        if err then return finish(false, err) end
      else
        stack[#stack] = nil
        local ok, rmdir_err = uv.fs_rmdir(top.path)
        if not ok then return finish(false, 'rmdir failed: ' .. top.path .. ' — ' .. tostring(rmdir_err)) end
      end
    end

    if #stack == 0 then return finish(true) end
    schedule_next()
  end

  -- 首个 entry 同步处理（文件直接删除、目录压栈），之后的工作全部分片异步执行；
  -- on_done 一律异步触发，调用方拿到 handle 后才会收到回调
  local first_err = ancestor_error or verify_directories() or visit(target)
  if first_err then
    vim.schedule(function() finish(false, first_err) end)
  elseif #stack == 0 then
    vim.schedule(function() finish(true) end)
  else
    schedule_next()
  end

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

---@class VVFsDeleteAsyncOptions
---@field on_done fun(ok: boolean, err?: string) 删除完成或首个失败时触发一次；cancel 不触发
---@field budget_ms? integer 单片最长占用主线程的毫秒数 @default 8

---@class VVFsDeleteAsyncHandle
---@field cancel fun() 停止删除（已删除的部分保留），幂等
---@field is_done fun(): boolean
