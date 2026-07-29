-- 路径补全候选生成
--
-- 把输入片段解析为扫描参数，并将原始路径合并为有序 CompleteItem

local Parser = require('vv-utils.path_completion.parser')
local Scanner = require('vv-utils.path_completion.scanner')

local M = {}

---@class vv-utils.path_completion.Item: VVCompletionItem
---@field menu string

---@param path string
---@return string
local function normalized(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
end

---@param matches vv-utils.path_completion.Match[]
---@param insertion_dir string
---@param glob boolean
---@return vv-utils.path_completion.Item[]
local function to_items(matches, insertion_dir, glob)
  local items = {}
  for _, match in ipairs(matches) do
    local suffix = match.directory and '/' or ''
    local value = glob and Parser.escape_glob(match.value) or match.value
    items[#items + 1] = {
      word = insertion_dir .. value .. suffix,
      abbr = match.value .. suffix,
      kind = match.directory and 'Folder' or 'File',
      menu = '[path]',
    }
  end
  return items
end

---@param items vv-utils.path_completion.Item[]
---@param additions vv-utils.path_completion.Item[]
---@param max_items integer
---@return vv-utils.path_completion.Item[]
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
    local left_depth = Parser.path_depth(left.word)
    local right_depth = Parser.path_depth(right.word)
    if left_depth ~= right_depth then return left_depth < right_depth end
    return left.word:lower() < right.word:lower()
  end)
  while #items > max_items do table.remove(items) end
  return items
end

---@param source string
---@param cwd string
---@param opts { directories_only: boolean, glob: boolean, max_items: integer, scan_max_items: integer, recursive: boolean?, timeout_ms: integer }
---@return {directory_part: string, needle: string, scan_dir: string}?, vv-utils.path_completion.Item[]?
local function request(source, cwd, opts)
  if source == '~' and not opts.glob then
    return nil, { { word = '~/', abbr = '~/', kind = 'Folder', menu = '[path]' } }
  end

  cwd = normalized(cwd)

  local directory_part, needle = source:match('^(.*[/\\])([^/\\]*)$')
  directory_part = directory_part or ''
  needle = needle or source

  if opts.glob and (Parser.has_unescaped_glob(directory_part) or Parser.has_unescaped_glob(needle)) then
    return nil, {}
  end

  local fs_directory = Parser.unescape_glob(directory_part)
  local scan_dir

  if not opts.glob and fs_directory:sub(1, 2) == '~/' then
    scan_dir = vim.fs.joinpath(vim.uv.os_homedir(), fs_directory:sub(3))
  elseif Parser.is_absolute(fs_directory) then
    scan_dir = fs_directory
  else
    scan_dir = vim.fs.joinpath(cwd, fs_directory)
  end

  return {
    directory_part = directory_part,
    needle = needle,
    scan_dir = normalized(scan_dir),
  }, nil
end

---@param source string
---@param cwd string
---@param opts { directories_only: boolean, glob: boolean, max_items: integer, scan_max_items: integer, recursive: boolean?, timeout_ms: integer }
---@return vv-utils.path_completion.Item[]
function M.complete(source, cwd, opts)
  local prepared, immediate = request(source, cwd, opts)
  if immediate then return immediate end
  assert(prepared, 'path completion request was not prepared')
  ---@cast prepared {directory_part: string, needle: string, scan_dir: string}
  local fs_needle = Parser.unescape_glob(prepared.needle)
  local direct = Scanner.direct(prepared.scan_dir, fs_needle, opts)
  local items = to_items(direct, prepared.directory_part, opts.glob)
  if opts.recursive and source:sub(1, 2) ~= './' then
    local parent = Parser.strip_relative_prefix(Parser.unescape_glob(prepared.directory_part))
    local descendants = Scanner.descendants(fs_needle, parent, normalized(cwd), opts)
    items = merge_items(items, to_items(descendants, '', opts.glob), opts.max_items)
  end
  return items
end

---异步生成路径候选；当前目录分批扫描，递归路径通过可取消 fd 进程查询
---@param source string
---@param cwd string
---@param opts { directories_only: boolean, glob: boolean, max_items: integer, scan_max_items: integer, recursive: boolean?, timeout_ms: integer }
---@param callback fun(items: vv-utils.path_completion.Item[])
---@return fun() cancel
function M.complete_async(source, cwd, opts, callback)
  local prepared, immediate = request(source, cwd, opts)
  if immediate then
    local cancelled = false
    vim.schedule(function()
      if not cancelled then callback(immediate) end
    end)
    return function() cancelled = true end
  end
  assert(prepared, 'path completion request was not prepared')
  ---@cast prepared {directory_part: string, needle: string, scan_dir: string}

  local cancelled = false
  local pending = opts.recursive and source:sub(1, 2) ~= './' and 2 or 1
  local direct_items = {}
  local descendant_items = {}
  local cancels = {}
  local fs_needle = Parser.unescape_glob(prepared.needle)

  local function done()
    if cancelled then return end
    pending = pending - 1
    if pending > 0 then return end
    callback(merge_items(direct_items, descendant_items, opts.max_items))
  end

  cancels[#cancels + 1] = Scanner.direct_async(prepared.scan_dir, fs_needle, opts, function(matches)
    direct_items = to_items(matches, prepared.directory_part, opts.glob)
    done()
  end)

  if pending == 2 then
    local parent = Parser.strip_relative_prefix(Parser.unescape_glob(prepared.directory_part))
    cancels[#cancels + 1] = Scanner.descendants_async(fs_needle, parent, normalized(cwd), opts, function(matches)
      descendant_items = to_items(matches, '', opts.glob)
      done()
    end)
  end

  return function()
    if cancelled then return end
    cancelled = true
    for _, cancel in ipairs(cancels) do cancel() end
  end
end

return M
