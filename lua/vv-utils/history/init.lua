-- 通用输入历史
--
-- 每个实例按字段维护独立历史，支持 Up / Down 式浏览与草稿恢复
-- 可选把稳定记录持久化到 stdpath('state')/<name>/history.json

local Data = require('vv-utils.history.data')
local Store = require('vv-utils.history.store')

local M = {}

---@class vv-utils.history.State
---@field items string[]
---@field cursor integer?
---@field draft string?
---@field shown string?

---@class vv-utils.history.Record
---@field field string
---@field value string

---@class vv-utils.history.Opts
---@field name string  实例名称，同时作为默认 state 子目录；仅允许字母、数字、点、下划线和连字符，且不能是 `.` / `..`
---@field max_entries? integer  每个字段最多保留的记录数 @default 50
---@field persist? boolean  是否跨 Neovim 重启持久化 @default false
---@field path? string  自定义历史文件路径，主要用于测试或兼容旧路径

---@class vv-utils.history.History
---@field name string
---@field max_entries integer
---@field persist boolean
---@field path string
---@field states table<string, vv-utils.history.State>
---@field store vv-utils.history.Store?
local History = {}
History.__index = History

---@param state vv-utils.history.State
local function reset_navigation(state)
  state.cursor = nil
  state.draft = nil
  state.shown = nil
end

---@param self vv-utils.history.History
---@param field string
---@return vv-utils.history.State
local function state_for(self, field)
  if not self.states[field] then self.states[field] = { items = {} } end
  return self.states[field]
end

---@param self vv-utils.history.History
---@param field string
---@param value string
---@return boolean changed
local function record_value(self, field, value)
  if value == '' then return false end

  local state = state_for(self, field)
  if state.items[#state.items] == value then
    reset_navigation(state)
    return false
  end

  Data.merge_value(state.items, value, self.max_entries)
  reset_navigation(state)
  return true
end

---@param self vv-utils.history.History
---@param fields table<string, string[]>
local function restore_fields(self, fields)
  self.states = {}
  for field, items in pairs(Data.normalize_fields(fields, self.max_entries)) do
    self.states[field] = { items = items }
  end
end

---@param self vv-utils.history.History
---@param records vv-utils.history.Record[]
local function persist_records(self, records)
  if not self.store then return end

  local fields = self.store:save(self:snapshot(), records)
  if fields then
    -- 把刚合并到磁盘的外部记录同步回当前实例，后续无需重启即可浏览
    restore_fields(self, fields)
  end
end

---创建彼此隔离的历史实例
---@param opts vv-utils.history.Opts
---@return vv-utils.history.History
function M.new(opts)
  assert(type(opts) == 'table', 'history.new: opts must be a table')
  assert(type(opts.name) == 'string'
    and opts.name ~= '.'
    and opts.name ~= '..'
    and opts.name:match('^[%w._-]+$'),
    'history.new: name must use safe filename characters and must not be . or ..')

  local max_entries = opts.max_entries or 50
  assert(type(max_entries) == 'number' and max_entries > 0 and max_entries % 1 == 0,
    'history.new: max_entries must be a positive integer')

  local path = opts.path or Store.default_path(opts.name)
  local self = setmetatable({
    name = opts.name,
    max_entries = max_entries,
    persist = opts.persist == true,
    path = path,
    states = {},
    store = nil,
  }, History)

  if self.persist then
    self.store = Store.new({
      name = self.name,
      path = self.path,
      max_entries = self.max_entries,
    })

    local fields = self.store:load()
    if fields then restore_fields(self, fields) end
  end

  return self
end

---记录一个字段值。空值不入历史，重复值移到最新位置
---@param field string
---@param value string
---@return boolean changed
function History:record(field, value)
  assert(type(field) == 'string' and field ~= '', 'history.record: field must be a non-empty string')
  assert(type(value) == 'string', 'history.record: value must be a string')
  if not record_value(self, field, value) then return false end

  persist_records(self, { { field = field, value = value } })
  return true
end

---批量记录多个字段，只执行一次持久化写入
---@param records vv-utils.history.Record[]
---@return integer changed_count
function History:record_many(records)
  assert(type(records) == 'table', 'history.record_many: records must be a table')

  local changed = {}
  for _, record in ipairs(records) do
    assert(type(record) == 'table', 'history.record_many: each record must be a table')
    assert(type(record.field) == 'string' and record.field ~= '',
      'history.record_many: field must be a non-empty string')
    assert(type(record.value) == 'string', 'history.record_many: value must be a string')
    if record_value(self, record.field, record.value) then changed[#changed + 1] = record end
  end

  if #changed > 0 then persist_records(self, changed) end
  return #changed
end

---返回更早的历史；没有记录时返回 nil
---@param field string
---@param current string
---@return string?
function History:previous(field, current)
  local state = state_for(self, field)
  if #state.items == 0 then return nil end

  if not state.cursor or current ~= state.shown then
    state.draft = current
    state.cursor = #state.items
  elseif state.cursor > 1 then
    state.cursor = state.cursor - 1
  end

  state.shown = state.items[state.cursor]
  return state.shown
end

---返回更新的历史；越过最新记录后恢复浏览前的草稿
---@param field string
---@param current string
---@return string?
function History:next(field, current)
  local state = state_for(self, field)
  if not state.cursor or current ~= state.shown then
    reset_navigation(state)
    return nil
  end

  if state.cursor < #state.items then
    state.cursor = state.cursor + 1
    state.shown = state.items[state.cursor]
    return state.shown
  end

  local draft = state.draft or ''
  reset_navigation(state)
  return draft
end

---导出仅包含稳定记录的副本，不包含浏览游标和临时草稿
---@return table<string, string[]>
function History:snapshot()
  local snapshot = {}
  for field, state in pairs(self.states) do
    local items = {}
    for i, value in ipairs(state.items) do items[i] = value end
    snapshot[field] = items
  end
  return snapshot
end

return M
