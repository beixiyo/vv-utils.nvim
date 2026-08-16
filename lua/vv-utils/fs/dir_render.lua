-- 目录属性与递归统计结果的人类可见文本渲染

local file_render = require('vv-utils.fs.file_render')
local highlight = require('vv-utils.fs.file_info_highlight')

local M = {}

---@param value integer
---@return string
local function group_digits(value)
  local text = tostring(value)
  local grouped = text:reverse():gsub('(%d%d%d)', '%1,'):reverse()
  return (grouped:gsub('^,', ''))
end

---@class VVFsDirLinesOptions
---@field display_path? string
---@field title? string @default 'Directory'
---@field scan? VVFsDirScanResult 递归统计；done=false 时渲染为扫描中

---@param info VVFsDirShallow
---@param opts? VVFsDirLinesOptions
---@return string[]
function M.lines(info, opts)
  opts = opts or {}

  local items = ('%s (%s dirs, %s files'):format(
    group_digits(info.entries),
    group_digits(info.dirs),
    group_digits(info.files)
  )
  items = info.links > 0
    and items .. (', %s links)'):format(group_digits(info.links))
    or items .. ')'

  local lines = {
    opts.title or 'Directory',
    '',
    'Path: ' .. (opts.display_path or info.path),
    'Items: ' .. items,
  }
  if info.modified then
    lines[#lines + 1] = 'Modified: ' .. os.date('%Y-%m-%d %H:%M:%S', info.modified)
  end

  local scan = opts.scan
  if not scan then return lines end

  -- 扫描中的数字是中间值，必须让它和最终值在视觉上可分，否则会被误读为结果
  local suffix = ''
  local prefix = ''
  if scan.truncated then
    suffix = ' ' .. highlight.markers.truncated .. (' at %s entries)'):format(group_digits(scan.entries))
    prefix = '≥ '
  elseif not scan.done then
    suffix = ' ' .. highlight.markers.pending
    prefix = '≥ '
  end

  lines[#lines + 1] = ''
  lines[#lines + 1] = ('Total size: %s%s%s'):format(
    prefix,
    file_render.format_size(scan.bytes),
    suffix ~= '' and suffix or (' (%s bytes)'):format(group_digits(scan.bytes))
  )
  lines[#lines + 1] = ('Total files: %s%s%s'):format(prefix, group_digits(scan.files), suffix)
  lines[#lines + 1] = ('Total dirs: %s%s%s'):format(prefix, group_digits(scan.dirs), suffix)
  if scan.links > 0 then
    lines[#lines + 1] = ('Links: %s%s%s'):format(prefix, group_digits(scan.links), suffix)
  end

  return lines
end

return M
