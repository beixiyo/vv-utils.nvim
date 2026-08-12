-- 文件事务适配层
--
-- 文件快照、未保存 buffer 检查和文件写入是 fs 的策略；顺序执行、预检、
-- 失败补偿、锁定和一层撤回由 vv-utils.transaction 统一负责

local Generic = require('vv-utils.transaction')
local io = require('vv-utils.fs.io')
local fs_path = require('vv-utils.fs.path')

local M = {}

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
      async = false,
      validate = function(_, _, _, phase)
        return self:_validate_entry(entry, phase == 'undo' and 'new' or 'old')
      end,
      apply = function()
        return self:_apply_entry(entry, 'old', 'new')
      end,
      compensate = function()
        return self:_compensate_entry(entry, 'new', 'old')
      end,
    }
  end
  return operations
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

---@class vv-utils.fs.TransactionOptions
---@field read? fun(path: string): string 文件读取器 @default vv-utils.fs.read_all
---@field write? fun(path: string, content: string) 文件写入器 @default vv-utils.fs.write_all
---@field check_modified_buffers? boolean 拒绝覆盖未保存的 Neovim buffer @default true

return M
