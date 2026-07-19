-- 文件内容事务
--
-- 每个实例独立保存最近一次成功事务。写入前校验全部快照，逐文件写入失败时
-- 反向补偿已触碰文件；补偿不完整后锁定实例，避免继续操作未知状态

local fs = require('vv-utils.fs')

local M = {}

---@class VVUtilsFileTransaction
local Transaction = {}
Transaction.__index = Transaction

---@param path string
---@return integer?
function Transaction:_modified_buffer(path)
  if not self.check_modified_buffers then return end

  local real = fs.realpath(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf)
      and vim.bo[buf].modified
      and fs.realpath(vim.api.nvim_buf_get_name(buf)) == real
    then
      return buf
    end
  end
end

---@param entries VVUtilsFileTransactionEntry[]
---@param field 'old'|'new'
---@return boolean, string?
function Transaction:_validate(entries, field)
  for _, entry in ipairs(entries) do
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
  end
  return true
end

---@param entry VVUtilsFileTransactionEntry
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

---@param attempted VVUtilsFileTransactionEntry[]
---@param from_field 'old'|'new'
---@param to_field 'old'|'new'
---@return string[] failures
function Transaction:_rollback(attempted, from_field, to_field)
  local failures = {}

  for i = #attempted, 1, -1 do
    local entry = attempted[i]
    local ok_read, content = pcall(self.read, entry.path)

    if not ok_read then
      failures[#failures + 1] = entry.path .. ' (rollback read failed: ' .. tostring(content) .. ')'
    elseif content ~= entry[to_field] then
      if content ~= entry[from_field] then
        failures[#failures + 1] = entry.path .. ' (file changed during rollback)'
      else
        local ok_write, write_err = pcall(self._write_verified, self, entry, from_field, to_field)
        if not ok_write then
          failures[#failures + 1] = entry.path .. ' (' .. tostring(write_err) .. ')'
        end
      end
    end
  end
  return failures
end

---@param entries VVUtilsFileTransactionEntry[]
---@return boolean ok
---@return string? error
---@return boolean? touched
function Transaction:apply(entries)
  if self.busy then return false, 'another file transaction is in progress' end
  if self.inconsistent then
    return false, 'previous transaction rollback is incomplete; restart Neovim after recovering the reported files'
  end
  if #entries == 0 then return false, 'no files changed' end

  self.busy = true
  local valid, validation_error = self:_validate(entries, 'old')
  if not valid then
    self.busy = false
    return false, validation_error
  end

  local attempted = {}
  for _, entry in ipairs(entries) do
    attempted[#attempted + 1] = entry
    local ok, error = pcall(self._write_verified, self, entry, 'old', 'new')

    if not ok then
      local rollback_failures = self:_rollback(attempted, 'new', 'old')
      self.busy = false
      self.inconsistent = #rollback_failures > 0

      local suffix = #rollback_failures > 0
        and '\nrollback failed:\n' .. table.concat(rollback_failures, '\n')
        or ''
      return false, tostring(error) .. suffix, true
    end
  end

  self.last = vim.deepcopy(entries)
  self.busy = false
  return true, nil, true
end

---@return boolean ok
---@return string? error
---@return integer? count
---@return boolean? touched
function Transaction:undo()
  if self.busy then return false, 'another file transaction is in progress' end
  if self.inconsistent then
    return false, 'previous transaction rollback is incomplete; restart Neovim after recovering the reported files'
  end
  if not self.last then return false, 'nothing to undo' end

  self.busy = true
  local valid, validation_error = self:_validate(self.last, 'new')
  if not valid then
    self.busy = false
    return false, validation_error
  end

  local attempted = {}
  for _, entry in ipairs(self.last) do
    attempted[#attempted + 1] = entry
    local ok, error = pcall(self._write_verified, self, entry, 'new', 'old')
    if not ok then
      local rollback_failures = self:_rollback(attempted, 'old', 'new')
      self.busy = false
      self.inconsistent = #rollback_failures > 0
      local suffix = #rollback_failures > 0
        and '\nrollback failed:\n' .. table.concat(rollback_failures, '\n')
        or ''
      return false, tostring(error) .. suffix, nil, true
    end
  end

  local count = #self.last
  self.last = nil
  self.busy = false
  return true, nil, count, true
end

---@return boolean
function Transaction:can_undo()
  return self.last ~= nil and not self.inconsistent
end

---创建状态互相隔离的文件事务实例
---@param opts? VVUtilsFileTransactionOptions
---@return VVUtilsFileTransaction
function M.new(opts)
  opts = opts or {}

  return setmetatable({
    read = opts.read or fs.read_all,
    write = opts.write or fs.write_all,
    check_modified_buffers = opts.check_modified_buffers ~= false,
    last = nil,
    busy = false,
    inconsistent = false,
  }, Transaction)
end

---@class VVUtilsFileTransactionEntry
---@field path string 文件路径 @default none
---@field old string 事务前的完整内容 @default none
---@field new string 事务后的完整内容 @default none

---@class VVUtilsFileTransactionOptions
---@field read? fun(path: string): string 文件读取器 @default vv-utils.fs.read_all
---@field write? fun(path: string, content: string) 文件写入器 @default vv-utils.fs.write_all
---@field check_modified_buffers? boolean 拒绝覆盖未保存的 Neovim buffer @default true

return M
