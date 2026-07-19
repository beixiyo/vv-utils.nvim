-- 路径候选扫描
--
-- 只负责从文件系统或 fd 收集、过滤和排序原始路径，不生成 CompleteItem

local Parser = require('vv-utils.path_completion.parser')

local uv = vim.uv

local M = {}

---@class vv-utils.path_completion.Match
---@field value string
---@field directory boolean

---@param path string
---@return boolean
local function is_directory(path)
  local stat = uv.fs_stat(path)
  return stat ~= nil and stat.type == 'directory'
end

---@param scan_dir string
---@param needle string
---@param opts { directories_only: boolean, max_items: integer }
---@return vv-utils.path_completion.Match[]
function M.direct(scan_dir, needle, opts)
  local handle = uv.fs_scandir(scan_dir)
  if not handle then return {} end

  local matches = {}
  local folded_needle = needle:lower()
  while true do
    local name, kind = uv.fs_scandir_next(handle)
    if not name then break end

    local hidden = name:sub(1, 1) == '.'
    local matches_prefix = name:lower():sub(1, #folded_needle) == folded_needle
    if matches_prefix and (not hidden or needle:sub(1, 1) == '.') then
      local path = vim.fs.joinpath(scan_dir, name)
      local directory = kind == 'directory' or (kind == 'link' and is_directory(path))
      if directory or not opts.directories_only then
        matches[#matches + 1] = { value = name, directory = directory }
      end
    end
  end

  table.sort(matches, function(left, right)
    if left.directory ~= right.directory then return left.directory end
    return left.value:lower() < right.value:lower()
  end)

  while #matches > opts.max_items do table.remove(matches) end
  return matches
end

---@param needle string
---@param parent string
---@param cwd string
---@param opts { directories_only: boolean, max_items: integer, timeout_ms: integer }
---@return vv-utils.path_completion.Match[]
function M.descendants(needle, parent, cwd, opts)
  if needle == '' or vim.fn.executable('fd') ~= 1 or not is_directory(cwd) then return {} end

  local args = {
    'fd',
    '--fixed-strings',
    '--ignore-case',
    '--color',
    'never',
    '--type',
    'directory',
  }
  if not opts.directories_only then vim.list_extend(args, { '--type', 'file' }) end
  if needle:sub(1, 1) == '.' then args[#args + 1] = '--hidden' end

  local scan_limit = math.min(10000, math.max(1000, opts.max_items * 20))
  vim.list_extend(args, { '--max-results', tostring(scan_limit), '--', needle })

  local ok, result = pcall(function()
    return vim.system(args, { cwd = cwd, text = true }):wait(opts.timeout_ms)
  end)
  if not ok or result.code ~= 0 or not result.stdout then return {} end

  local folded_needle = needle:lower()
  local folded_parent = parent:lower():gsub('\\', '/')
  local matches = {}
  for output in result.stdout:gmatch('[^\r\n]+') do
    local relative = Parser.strip_relative_prefix(output):gsub('\\', '/')
    local stat = uv.fs_stat(vim.fs.joinpath(cwd, relative))
    local directory = stat ~= nil and stat.type == 'directory'
    local basename = vim.fs.basename(relative)
    local current_parent = vim.fs.dirname(relative)
    if current_parent == '.' then current_parent = '' end

    if basename:lower():sub(1, #folded_needle) == folded_needle
      and Parser.ends_with_path(current_parent:lower(), folded_parent)
      and (directory or not opts.directories_only)
    then
      matches[#matches + 1] = { value = relative, directory = directory }
    end
  end

  table.sort(matches, function(left, right)
    if left.directory ~= right.directory then return left.directory end
    local left_depth = Parser.path_depth(left.value)
    local right_depth = Parser.path_depth(right.value)
    if left_depth ~= right_depth then return left_depth < right_depth end
    return left.value:lower() < right.value:lower()
  end)

  while #matches > opts.max_items do table.remove(matches) end
  return matches
end

return M
