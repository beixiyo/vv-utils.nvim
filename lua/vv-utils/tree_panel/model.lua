-- Tree panel 的纯数据模型：负责节点校验、折叠状态与可见行展开

local M = {}


---@param nodes VVTreePanelNode[]
---@param folded table<string, boolean>
---@return VVTreePanelRow[]
function M.flatten(nodes, folded)
  local rows = {}
  local seen = {}

  local function visit(items, depth, parent)
    for index, node in ipairs(items or {}) do
      assert(type(node.id) == 'string' and node.id ~= '', 'tree panel node.id must be a non-empty string')
      assert(not seen[node.id], ('duplicate tree panel node id: %s'):format(node.id))
      seen[node.id] = true

      rows[#rows + 1] = {
        node = node,
        depth = depth,
        parent = parent,
        is_last = index == #items,
      }

      local has_children = node.children and #node.children > 0
      local is_folded = folded[node.id]
      if is_folded == nil then is_folded = node.expanded == false end
      if has_children and not is_folded then visit(node.children, depth + 1, node) end
    end
  end

  visit(nodes or {}, 0, nil)

  return rows
end

---@param nodes VVTreePanelNode[]
---@param folded table<string, boolean>
---@param value boolean
function M.fold_all(nodes, folded, value)
  local function visit(items)
    for _, node in ipairs(items or {}) do
      if node.children and #node.children > 0 then
        folded[node.id] = value
        visit(node.children)
      end
    end
  end

  visit(nodes)
end

---@param nodes VVTreePanelNode[]
---@param id string
---@return VVTreePanelNode?
function M.find(nodes, id)
  for _, node in ipairs(nodes or {}) do
    if node.id == id then return node end

    local found = M.find(node.children or {}, id)
    if found then return found end
  end
end

--- 在可导航行之间循环移动。当前行不在集合内时，先选择移动方向上的最近一行。
---@param lines integer[]
---@param current integer
---@param delta -1|1
---@param count? integer
---@return integer?
function M.move_target(lines, current, delta, count)
  assert(delta == -1 or delta == 1, 'tree panel move delta must be -1 or 1')
  if #lines == 0 then return nil end

  count = math.max(1, math.floor(tonumber(count) or 1))

  local index
  for current_index, line in ipairs(lines) do
    if line == current then
      index = current_index
      break
    end

    if delta == 1 and line > current then
      index = current_index
      count = count - 1
      break
    end
  end

  if not index and delta == -1 then
    for current_index = #lines, 1, -1 do
      if lines[current_index] < current then
        index = current_index
        count = count - 1
        break
      end
    end
  end

  index = index or (delta == 1 and 1 or #lines)
  return lines[((index - 1 + delta * count) % #lines) + 1]
end

return M
