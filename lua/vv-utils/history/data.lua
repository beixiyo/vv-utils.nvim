-- 输入历史的稳定数据操作
--
-- 只处理已记录值，不涉及浏览游标、文件系统或 Neovim UI

local M = {}

---把值移动到列表末尾，并按上限删除最旧记录
---@param items string[]
---@param value string
---@param max_entries integer
function M.merge_value(items, value, max_entries)
  for i = #items, 1, -1 do
    if items[i] == value then
      table.remove(items, i)
      break
    end
  end

  items[#items + 1] = value
  while #items > max_entries do table.remove(items, 1) end
end

---清洗持久化数据：忽略无效字段、空值并重新应用去重和条数限制
---@param fields any
---@param max_entries integer
---@return table<string, string[]>
function M.normalize_fields(fields, max_entries)
  local normalized = {}
  if type(fields) ~= 'table' then return normalized end

  for field, values in pairs(fields) do
    if type(field) == 'string' and field ~= '' and type(values) == 'table' then
      local items = {}
      for _, value in ipairs(values) do
        if type(value) == 'string' and value ~= '' then
          M.merge_value(items, value, max_entries)
        end
      end
      if #items > 0 then normalized[field] = items end
    end
  end

  return normalized
end

return M
