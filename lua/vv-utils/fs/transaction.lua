-- 文件事务适配层
--
-- 文件快照、未保存 buffer 检查和文件写入是 fs 的策略；顺序执行、预检、
-- 失败补偿、锁定和一层撤回由 vv-utils.transaction 统一负责
--
-- 同步与分片异步共用同一组 operation：operation 一律以 callback 完成，
-- 同步 apply / undo 时 callback 当场触发；apply_async / undo_async 期间由 pacer 决定
-- 是当场触发还是超出时间预算后经 uv timer 让出主线程再触发（不用 vim.schedule 自递归，
-- 原因见 dir_scan.lua）。让出只发生在两个文件之间，单个文件的读写校验始终同步完成

local Generic = require('vv-utils.transaction')
local io = require('vv-utils.fs.io')
local fs_path = require('vv-utils.fs.path')

local uv = vim.uv
local unpack_values = unpack or table.unpack

local M = {}

local DEFAULT_BUDGET_MS = 8

---@class vv-utils.fs.Transaction
local Transaction = {}

local BUSY_ERROR = 'another file transaction is in progress'
local LOCKED_ERROR = 'previous transaction rollback is incomplete; restart Neovim after recovering the reported files'

local function map_error(error)
  if error == Generic.BUSY_ERROR then return BUSY_ERROR end
  if error == Generic.LOCKED_ERROR then return LOCKED_ERROR end
  if error == 'no operations' then return 'no files changed' end

  -- 通用事务使用机制名称；文件事务继续报告历史公共 API 中的 rollback
  return tostring(error):gsub('\ncompensation failed:\n', '\nrollback failed:\n')
end

local function clone_entries(entries)
  return vim.deepcopy(entries)
end

---@param path string
---@return integer?
function Transaction:_modified_buffer(path)
  if not self.check_modified_buffers then return end

  local real = fs_path.realpath(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf)
      and vim.bo[buf].modified
      and fs_path.realpath(vim.api.nvim_buf_get_name(buf)) == real
    then
      return buf
    end
  end
end

---@param entry vv-utils.fs.TransactionEntry
---@param field 'old'|'new'
---@return boolean, string?
function Transaction:_validate_entry(entry, field)
  local buf = self:_modified_buffer(entry.path)
  if buf then
    return false, string.format('unsaved buffer: %s', vim.api.nvim_buf_get_name(buf))
  end

  local ok, content = pcall(self.read, entry.path)
  if not ok then
    return false, string.format('read failed: %s (%s)', entry.path, tostring(content))
  end
  if content ~= entry[field] then
    return false, string.format('file changed since transaction snapshot: %s', entry.path)
  end
  return true
end

---@param entry vv-utils.fs.TransactionEntry
---@param from_field 'old'|'new'
---@param to_field 'old'|'new'
function Transaction:_write_verified(entry, from_field, to_field)
  local before = self.read(entry.path)
  if before ~= entry[from_field] then
    error('file changed before write: ' .. entry.path)
  end

  self.write(entry.path, entry[to_field])
  local content = self.read(entry.path)
  if content ~= entry[to_field] then
    error('write verification failed: ' .. entry.path)
  end
end

---@param entry vv-utils.fs.TransactionEntry
---@param from_field 'old'|'new'
---@param to_field 'old'|'new'
---@return boolean ok
---@return string|vv-utils.transaction.Failure? error
function Transaction:_apply_entry(entry, from_field, to_field)
  local ok_before, before = pcall(self.read, entry.path)
  if not ok_before then return false, Generic.failure(before, false) end
  if before ~= entry[from_field] then
    return false, Generic.failure('file changed before write: ' .. entry.path, false)
  end

  local ok_write, write_error = pcall(self.write, entry.path, entry[to_field])
  local ok_after, content = pcall(self.read, entry.path)
  if not ok_write then
    return false, Generic.failure(write_error, not ok_after or content ~= entry[from_field])
  end
  if not ok_after then return false, Generic.failure(content, true) end
  if content ~= entry[to_field] then
    return false, Generic.failure('write verification failed: ' .. entry.path, true)
  end
  return true
end

---@param entry vv-utils.fs.TransactionEntry
---@param from_field 'old'|'new'
---@param to_field 'old'|'new'
---@return boolean ok
---@return string? error
function Transaction:_compensate_entry(entry, from_field, to_field)
  local ok_read, content = pcall(self.read, entry.path)
  if not ok_read then
    return false, Generic.failure('rollback read failed: ' .. tostring(content), false)
  end

  if content == entry[to_field] then return true end
  if content ~= entry[from_field] then
    return false, Generic.failure('file changed during rollback', false)
  end

  return self:_apply_entry(entry, from_field, to_field)
end

-- 交付一个 operation 结果：无 pacer（同步调用）或仍在本片预算内时当场交付，
-- 否则经 uv timer 让出一轮事件循环后再交付
---@param step vv-utils.fs.TransactionStep
---@param done fun(...)
function Transaction:_settle(step, done, ...)
  local pacer = self._pacer
  if not pacer then return done(...) end

  if pacer.step ~= step then
    pacer.step = step
    pacer.done = 0
  end
  pacer.done = pacer.done + 1
  if pacer.on_progress then
    pcall(pacer.on_progress, { step = step, done = pacer.done, total = pacer.total })
  end

  if (uv.hrtime() - pacer.slice_started) / 1e6 < pacer.budget_ms then return done(...) end

  local args = { n = select('#', ...), ... }
  pacer.timer:start(0, 0, vim.schedule_wrap(function()
    pacer.slice_started = uv.hrtime()
    done(unpack_values(args, 1, args.n))
  end))
end

---@param entries vv-utils.fs.TransactionEntry[]
---@return vv-utils.transaction.Operation[]
function Transaction:_operations(entries)
  local operations = {}
  for index, original in ipairs(entries) do
    local entry = {
      path = original.path,
      old = original.old,
      new = original.new,
    }

    operations[index] = {
      name = entry.path,
      async = true,
      validate = function(_, done, _, phase)
        self:_settle('validate', done, self:_validate_entry(entry, phase == 'undo' and 'new' or 'old'))
      end,
      apply = function(_, done, _, phase)
        -- 分片执行时预检与写入之间会让出主线程，期间用户可能改出未保存 buffer；写入前复查
        -- undo 失败后的恢复（undo-recover）同样走 apply，此时要尽力恢复，不复查
        local buf = phase == 'apply' and self:_modified_buffer(entry.path)
        if buf then
          local message = string.format('unsaved buffer: %s', vim.api.nvim_buf_get_name(buf))
          return self:_settle('apply', done, false, Generic.failure(message, false))
        end
        self:_settle('apply', done, self:_apply_entry(entry, 'old', 'new'))
      end,
      compensate = function(_, done, _, phase)
        -- 正常 undo 同样可能在预检后让出；失败补偿则必须尽力恢复磁盘，不套用此保护
        local buf = phase == 'undo' and self:_modified_buffer(entry.path)
        if buf then
          local message = string.format('unsaved buffer: %s', vim.api.nvim_buf_get_name(buf))
          return self:_settle('compensate', done, false, Generic.failure(message, false))
        end
        self:_settle('compensate', done, self:_compensate_entry(entry, 'new', 'old'))
      end,
    }
  end
  return operations
end

-- 以 pacer 运行一次核心事务；结果一律异步交付给 deliver
---@param opts vv-utils.fs.TransactionAsyncOptions
---@param total integer
---@param run fun(callback: fun(ok: boolean, error?: any, result?: vv-utils.transaction.Result))
---@param deliver fun(ok: boolean, error?: any, result?: vv-utils.transaction.Result)
function Transaction:_run_paced(opts, total, run, deliver)
  assert(type(opts) == 'table' and type(opts.on_done) == 'function', 'fs transaction: opts.on_done is required')

  local busy = self._core:is_busy()
  local timer = not busy and uv.new_timer() or nil
  if timer then
    self._pacer = {
      budget_ms = opts.budget_ms or DEFAULT_BUDGET_MS,
      slice_started = uv.hrtime(),
      timer = timer,
      total = total,
      on_progress = opts.on_progress,
    }
  end

  local returned = false
  run(function(ok, error, result)
    -- busy 被拒时 pacer 属于正在运行的另一次事务，不能清掉
    if timer then
      self._pacer = nil
      if not timer:is_closing() then timer:close() end
    end
    if returned then return deliver(ok, error, result) end
    vim.schedule(function() deliver(ok, error, result) end)
  end)
  returned = true
end

---@param entries vv-utils.fs.TransactionEntry[]
---@return boolean? ok
---@return string? error
---@return boolean? touched
function Transaction:apply(entries)
  local ok, error, result = self._core:run(self:_operations(entries))
  error = error and map_error(error) or nil

  if ok then
    self._last_entries = clone_entries(entries)
    return true, nil, true
  end

  if result and result.touched > 0 then return false, error, true end
  return false, error
end

---@return boolean ok
---@return string? error
---@return integer? count
---@return boolean? touched
function Transaction:undo()
  local ok, error, result = self._core:undo()
  error = error and map_error(error) or nil

  if ok then
    local count = result and result.count or nil
    self._last_entries = nil
    return true, nil, count, true
  end

  if result and result.touched > 0 then return false, error, nil, true end
  return false, error
end

---分片异步 apply：语义与 apply 相同（全部预检 → 顺序写入 → 失败逆序回滚），
---每片按时间预算处理若干文件后让出主线程；on_done 一律异步触发且只触发一次
---开始后不可取消：中途放弃会留下半写状态，调用方只能等待完成或回滚
---@param entries vv-utils.fs.TransactionEntry[]
---@param opts vv-utils.fs.TransactionAsyncOptions
function Transaction:apply_async(entries, opts)
  self:_run_paced(opts, #entries, function(callback)
    self._core:run(self:_operations(entries), nil, callback)
  end, function(ok, error, result)
    error = error and map_error(error) or nil
    if ok then
      self._last_entries = clone_entries(entries)
      return opts.on_done(true, nil, true)
    end
    opts.on_done(false, error, (result and result.touched > 0) or nil)
  end)
end

---分片异步 undo：语义与 undo 相同；on_done 收到 (ok, error, count, touched)，一律异步触发
---开始后不可取消，理由同 apply_async
---@param opts vv-utils.fs.TransactionUndoAsyncOptions
function Transaction:undo_async(opts)
  local total = self._last_entries and #self._last_entries or 0
  self:_run_paced(opts, total, function(callback)
    self._core:undo(callback)
  end, function(ok, error, result)
    error = error and map_error(error) or nil
    if ok then
      self._last_entries = nil
      return opts.on_done(true, nil, result and result.count or nil, true)
    end
    opts.on_done(false, error, nil, (result and result.touched > 0) or nil)
  end)
end

---@return boolean
function Transaction:can_undo()
  return self._core:can_undo()
end

---@return boolean
function Transaction:is_busy()
  return self._core:is_busy()
end

---@return boolean
function Transaction:is_locked()
  return self._core:is_locked()
end

---创建状态互相隔离的文件事务实例
---@param opts? vv-utils.fs.TransactionOptions
---@return vv-utils.fs.Transaction
function M.new(opts)
  opts = opts or {}

  local transaction = {
    _core = Generic.new(),
    read = opts.read or io.read_all,
    write = opts.write or io.write_all,
    check_modified_buffers = opts.check_modified_buffers ~= false,
    _last_entries = nil,
    _pacer = nil,
  }

  return setmetatable(transaction, {
    __index = function(self, key)
      local method = Transaction[key]
      if method ~= nil then return method end
      if key == 'busy' then return self._core.busy end
      if key == 'inconsistent' then return self._core.inconsistent end
      if key == 'locked' then return self._core.locked end
      if key == 'last' then return self._last_entries end
      return nil
    end,
  })
end

---@class vv-utils.fs.TransactionEntry
---@field path string 文件路径 @default none
---@field old string 事务前的完整内容 @default none
---@field new string 事务后的完整内容 @default none

---@alias vv-utils.fs.TransactionStep
---| 'validate' 预检快照与未保存 buffer
---| 'apply' 写入（undo 失败后的恢复也计入此步）
---| 'compensate' 回滚或 undo 写回

---@class vv-utils.fs.TransactionProgress
---@field step vv-utils.fs.TransactionStep 当前步骤；切换步骤时 done 从 1 重新计数
---@field done integer 本步骤已处理的文件数
---@field total integer 事务涉及的文件总数

---@class vv-utils.fs.TransactionAsyncOptions
---@field on_done fun(ok: boolean, error?: string, touched?: boolean) 完成、失败或被拒时异步触发一次
---@field on_progress? fun(progress: vv-utils.fs.TransactionProgress) 每处理完一个文件触发；抛错被忽略
---@field budget_ms? integer 单片最长占用主线程的毫秒数（至少处理一个文件） @default 8

---@class vv-utils.fs.TransactionUndoAsyncOptions
---@field on_done fun(ok: boolean, error?: string, count?: integer, touched?: boolean) 同 apply_async
---@field on_progress? fun(progress: vv-utils.fs.TransactionProgress)
---@field budget_ms? integer @default 8

---@class vv-utils.fs.TransactionOptions
---@field read? fun(path: string): string 文件读取器 @default vv-utils.fs.read_all
---@field write? fun(path: string, content: string) 文件写入器 @default vv-utils.fs.write_all
---@field check_modified_buffers? boolean 拒绝覆盖未保存的 Neovim buffer @default true

return M
