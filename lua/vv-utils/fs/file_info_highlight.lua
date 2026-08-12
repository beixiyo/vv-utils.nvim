-- 文件属性 buffer 高亮：提供共享分组并按 title / label / value 结构应用 extmark

local api = vim.api

local M = {}
local namespace = api.nvim_create_namespace('vv-utils.file-info')

local groups = {
  title = 'VVUtilsFileInfoTitle',
  label = 'VVUtilsFileInfoLabel',
  value = 'VVUtilsFileInfoValue',
  path = 'VVUtilsFileInfoPath',
  positive = 'VVUtilsFileInfoPositive',
  pending = 'VVUtilsFileInfoPending',
  truncated = 'VVUtilsFileInfoTruncated',
}

-- 属性值的状态标记：由渲染方（dir_info 等）拼进 value，高亮方据此选择配色
-- 两侧共用同一份字面量，避免各写一份文案后对不上
M.markers = {
  pending = '(scanning…)',
  truncated = '(truncated',
}

local function setup_groups()
  for name, link in pairs({
    [groups.title] = 'Title',
    [groups.label] = 'Comment',
    [groups.value] = 'String',
    [groups.path] = 'Directory',
    [groups.positive] = 'DiagnosticOk',
    [groups.pending] = 'DiagnosticHint',
    [groups.truncated] = 'WarningMsg',
  }) do
    api.nvim_set_hl(0, name, { default = true, link = link })
  end
end

local function value_group(label, value)
  if value:find(M.markers.truncated, 1, true) then return groups.truncated end
  if value:find(M.markers.pending, 1, true) then return groups.pending end
  if label == 'Path' then return groups.path end
  if label == 'Executable' and value == 'Yes' then return groups.positive end
  return groups.value
end

---@param buf integer
---@return boolean applied
function M.apply(buf)
  if not api.nvim_buf_is_valid(buf) then return false end
  setup_groups()
  api.nvim_buf_clear_namespace(buf, namespace, 0, -1)

  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  if lines[1] and lines[1] ~= '' then
    api.nvim_buf_set_extmark(buf, namespace, 0, 0, {
      end_col = #lines[1],
      hl_group = groups.title,
    })
  end

  for row = 2, #lines do
    local line = lines[row]
    local label, value = line:match('^([^:]+):%s*(.*)$')
    if label then
      local value_start = #label + 2
      api.nvim_buf_set_extmark(buf, namespace, row - 1, 0, {
        end_col = #label + 1,
        hl_group = groups.label,
      })
      if value ~= '' then
        api.nvim_buf_set_extmark(buf, namespace, row - 1, value_start, {
          end_col = #line,
          hl_group = value_group(label, value),
        })
      end
    end
  end

  return true
end

return M
