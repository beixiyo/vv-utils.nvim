-- 路径候选引擎
--
-- 只负责根据输入、光标和 cwd 生成补全项，不绑定具体输入 UI：
--   * glob()      识别顶层逗号分段，并保留 ! / ./ 搜索简写
--   * directory() 补全普通目录路径（供 Cwd 等字段使用）

local uv = vim.uv

local M = {}

local GLOB_ESCAPE_TARGETS = '[,{}%[%]*?!\\]'
local DEFAULT_TIMEOUT_MS = 250

---@param path string
---@return boolean
local function is_absolute(path)
  return path:sub(1, 1) == '/'
    or path:match('^%a:[/\\]') ~= nil
    or path:match('^[/\\][/\\]') ~= nil
end

---@param char string?
---@return boolean
local function is_escape_target(char)
  return char ~= nil and char:match(GLOB_ESCAPE_TARGETS) ~= nil
end

---@param value string
---@return string
local function unescape_glob(value)
  local chars = {}
  local index = 1

  while index <= #value do
    local char = value:sub(index, index)
    local next_char = index < #value and value:sub(index + 1, index + 1) or nil
    if char == '\\' and is_escape_target(next_char) then
      chars[#chars + 1] = next_char
      index = index + 2
    elseif char == '\\' then
      chars[#chars + 1] = '/'
      index = index + 1
    else
      chars[#chars + 1] = char
      index = index + 1
    end
  end

  return table.concat(chars)
end

---@param value string
---@return string
local function escape_glob(value)
  return (value:gsub('([,{}%[%]*?!\\])', '\\%1'))
end

---@param value string
---@return boolean
local function has_unescaped_glob(value)
  local escaped = false
  for index = 1, #value do
    local char = value:sub(index, index)
    if escaped then
      escaped = false
    elseif char == '\\' and is_escape_target(value:sub(index + 1, index + 1)) then
      escaped = true
    elseif char:match('[{}%[%]*?]') then
      return true
    end
  end
  return false
end

---@param input string
---@param cursor integer 0-based byte offset
---@return integer start_col 0-based byte offset
local function glob_segment_start(input, cursor)
  local brace_depth = 0
  local in_class = false
  local start = 1
  local index = 1

  while index <= cursor do
    local char = input:sub(index, index)
    local next_char = index < cursor and input:sub(index + 1, index + 1) or nil

    if char == '\\' and is_escape_target(next_char) then
      index = index + 2
    elseif char == '[' and not in_class then
      in_class = true
      index = index + 1
    elseif char == ']' and in_class then
      in_class = false
      index = index + 1
    elseif char == '{' and not in_class then
      brace_depth = brace_depth + 1
      index = index + 1
    elseif char == '}' and not in_class then
      brace_depth = math.max(0, brace_depth - 1)
      index = index + 1
    elseif char == ',' and brace_depth == 0 and not in_class then
      start = index + 1
      index = index + 1
    else
      index = index + 1
    end
  end

  while start <= cursor and input:sub(start, start):match('%s') do
    start = start + 1
  end
  return start - 1
end

---@param path string
---@return string
local function normalized(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
end

---@param path string
---@return boolean
local function is_directory(path)
  local stat = uv.fs_stat(path)
  return stat ~= nil and stat.type == 'directory'
end

---@param scan_dir string
---@param needle string
---@param insertion_dir string
---@param opts { directories_only: boolean, glob: boolean, max_items: integer }
---@return vim.CompleteItem[]
local function scan(scan_dir, needle, insertion_dir, opts)
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
        matches[#matches + 1] = {
          name = name,
          directory = directory,
        }
      end
    end
  end

  table.sort(matches, function(left, right)
    if left.directory ~= right.directory then return left.directory end
    return left.name:lower() < right.name:lower()
  end)

  local items = {}
  for index = 1, math.min(#matches, opts.max_items) do
    local match = matches[index]
    local name = opts.glob and escape_glob(match.name) or match.name
    local suffix = match.directory and '/' or ''
    items[#items + 1] = {
      word = insertion_dir .. name .. suffix,
      abbr = match.name .. suffix,
      kind = match.directory and 'Folder' or 'File',
      menu = '[path]',
    }
  end
  return items
end

---@param value string
---@return string
local function strip_relative_prefix(value)
  return value:gsub('^%.[/\\]', ''):gsub('[/\\]+$', '')
end

---@param path string
---@return integer
local function path_depth(path)
  local _, count = path:gsub('[/\\]', '')
  return count
end

---@param path string
---@param suffix string
---@return boolean
local function ends_with_path(path, suffix)
  if suffix == '' then return true end
  if path == suffix then return true end
  return #path > #suffix and path:sub(-#suffix - 1) == '/' .. suffix
end

---@param source string
---@param cwd string
---@param opts { directories_only: boolean, glob: boolean, max_items: integer, timeout_ms: integer }
---@return vim.CompleteItem[]
local function scan_descendants(source, cwd, opts)
  if source == '' or vim.fn.executable('fd') ~= 1 or not is_directory(cwd) then return {} end

  local directory_part, needle = source:match('^(.*[/\\])([^/\\]*)$')
  directory_part = strip_relative_prefix(unescape_glob(directory_part or ''))
  needle = unescape_glob(needle or source)
  if needle == '' then return {} end

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
  local folded_parent = directory_part:lower():gsub('\\', '/')
  local matches = {}
  for output in result.stdout:gmatch('[^\r\n]+') do
    local relative = strip_relative_prefix(output):gsub('\\', '/')
    local stat = uv.fs_stat(vim.fs.joinpath(cwd, relative))
    local directory = stat ~= nil and stat.type == 'directory'
    local basename = vim.fs.basename(relative)
    local parent = vim.fs.dirname(relative)
    if parent == '.' then parent = '' end

    if basename:lower():sub(1, #folded_needle) == folded_needle
      and ends_with_path(parent:lower(), folded_parent)
      and (directory or not opts.directories_only)
    then
      matches[#matches + 1] = {
        relative = relative,
        directory = directory,
      }
    end
  end

  table.sort(matches, function(left, right)
    if left.directory ~= right.directory then return left.directory end
    local left_depth = path_depth(left.relative)
    local right_depth = path_depth(right.relative)
    if left_depth ~= right_depth then return left_depth < right_depth end
    return left.relative:lower() < right.relative:lower()
  end)

  local items = {}
  for index = 1, math.min(#matches, opts.max_items) do
    local match = matches[index]
    local suffix = match.directory and '/' or ''
    local word = opts.glob and escape_glob(match.relative) or match.relative
    items[#items + 1] = {
      word = word .. suffix,
      abbr = match.relative .. suffix,
      kind = match.directory and 'Folder' or 'File',
      menu = '[path]',
    }
  end
  return items
end

---@param items vim.CompleteItem[]
---@param additions vim.CompleteItem[]
---@param max_items integer
---@return vim.CompleteItem[]
local function merge_items(items, additions, max_items)
  local seen = {}
  for _, item in ipairs(items) do seen[item.word] = true end
  for _, item in ipairs(additions) do
    if not seen[item.word] then
      items[#items + 1] = item
      seen[item.word] = true
    end
  end
  table.sort(items, function(left, right)
    local left_directory = left.kind == 'Folder'
    local right_directory = right.kind == 'Folder'
    if left_directory ~= right_directory then return left_directory end
    local left_depth = path_depth(left.word)
    local right_depth = path_depth(right.word)
    if left_depth ~= right_depth then return left_depth < right_depth end
    return left.word:lower() < right.word:lower()
  end)
  while #items > max_items do table.remove(items) end
  return items
end

---@param source string
---@param cwd string
---@param opts { directories_only: boolean, glob: boolean, max_items: integer, recursive: boolean?, timeout_ms: integer }
---@return vim.CompleteItem[]
local function complete_source(source, cwd, opts)
  if source == '~' and not opts.glob then
    return { { word = '~/', abbr = '~/', kind = 'Folder', menu = '[path]' } }
  end

  local directory_part, needle = source:match('^(.*[/\\])([^/\\]*)$')
  directory_part = directory_part or ''
  needle = needle or source

  if opts.glob and (has_unescaped_glob(directory_part) or has_unescaped_glob(needle)) then
    return {}
  end

  local fs_directory = unescape_glob(directory_part)
  local fs_needle = unescape_glob(needle)
  local scan_dir

  if not opts.glob and fs_directory:sub(1, 2) == '~/' then
    scan_dir = vim.fs.joinpath(vim.uv.os_homedir(), fs_directory:sub(3))
  elseif is_absolute(fs_directory) then
    scan_dir = fs_directory
  else
    scan_dir = vim.fs.joinpath(cwd, fs_directory)
  end

  local items = scan(normalized(scan_dir), fs_needle, directory_part, opts)
  if opts.recursive and source:sub(1, 2) ~= './' then
    items = merge_items(items, scan_descendants(source, cwd, opts), opts.max_items)
  end
  return items
end

---@param input string
---@param opts? vv-utils.path_completion.GlobOpts
---@return vv-utils.path_completion.Result
function M.glob(input, opts)
  opts = opts or {}
  input = input or ''
  local cursor = math.max(0, math.min(opts.cursor or #input, #input))
  local start_col = glob_segment_start(input, cursor)
  local source = input:sub(start_col + 1, cursor)
  local prefix = ''

  if source:sub(1, 1) == '!' then
    prefix = '!'
    source = source:sub(2)
  end

  if source:match('^%.%./') or source == '..' or is_absolute(source) then
    return { start_col = start_col, items = {} }
  end

  local cwd = normalized(opts.cwd or uv.cwd())
  local items = complete_source(source, cwd, {
    directories_only = false,
    glob = true,
    max_items = opts.max_items or 200,
    recursive = true,
    timeout_ms = opts.timeout_ms or DEFAULT_TIMEOUT_MS,
  })
  if prefix ~= '' then
    for _, item in ipairs(items) do item.word = prefix .. item.word end
  end

  return { start_col = start_col, items = items }
end

---@param input string
---@param opts? vv-utils.path_completion.DirectoryOpts
---@return vv-utils.path_completion.Result
function M.directory(input, opts)
  opts = opts or {}
  input = input or ''
  local cursor = math.max(0, math.min(opts.cursor or #input, #input))
  local start_col = 0
  while start_col < cursor and input:sub(start_col + 1, start_col + 1):match('%s') do
    start_col = start_col + 1
  end

  local source = input:sub(start_col + 1, cursor)
  local cwd = normalized(opts.cwd or uv.cwd())
  return {
    start_col = start_col,
    items = complete_source(source, cwd, {
      directories_only = true,
      glob = false,
      max_items = opts.max_items or 200,
      timeout_ms = opts.timeout_ms or DEFAULT_TIMEOUT_MS,
    }),
  }
end

---@class vv-utils.path_completion.GlobOpts
---@field cwd? string 候选路径的搜索根 @default vim.uv.cwd()
---@field cursor? integer 0-based byte 光标位置 @default #input
---@field max_items? integer 最大候选数 @default 200
---@field timeout_ms? integer 递归路径查询超时毫秒数 @default 250

---@class vv-utils.path_completion.DirectoryOpts
---@field cwd? string 相对路径的搜索根 @default vim.uv.cwd()
---@field cursor? integer 0-based byte 光标位置 @default #input
---@field max_items? integer 最大候选数 @default 200
---@field timeout_ms? integer 路径查询超时毫秒数 @default 250

---@class vv-utils.path_completion.Result
---@field start_col integer 需要替换的 0-based byte 起始列 @default 0
---@field items vim.CompleteItem[] 补全候选 @default {}

return M
