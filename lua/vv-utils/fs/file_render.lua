-- 文件属性的人类可见文本渲染

local M = {}

---@param size integer
---@return string
function M.format_size(size)
  if size < 1024 then return size .. ' B' end
  if size < 1024 * 1024 then return ('%.1f KiB'):format(size / 1024) end
  if size < 1024 * 1024 * 1024 then return ('%.1f MiB'):format(size / 1024 / 1024) end
  return ('%.1f GiB'):format(size / 1024 / 1024 / 1024)
end

---@class VVFsFileInfoLinesOptions
---@field display_path? string
---@field title? string @default 'Binary file'

---@param info VVFsFileInfo
---@param opts? VVFsFileInfoLinesOptions
---@return string[]
function M.lines(info, opts)
  opts = opts or {}
  local lines = {
    opts.title or 'Binary file',
    '',
    'Path: ' .. (opts.display_path or info.path),
    'Type: ' .. info.kind,
  }

  if info.architecture then lines[#lines + 1] = 'Architecture: ' .. info.architecture end
  if info.size then
    lines[#lines + 1] = ('Size: %s (%d bytes)'):format(M.format_size(info.size), info.size)
  end
  lines[#lines + 1] = 'Executable: ' .. (info.executable and 'Yes' or 'No')
  if info.modified then
    lines[#lines + 1] = 'Modified: ' .. os.date('%Y-%m-%d %H:%M:%S', info.modified)
  end

  return lines
end

return M
