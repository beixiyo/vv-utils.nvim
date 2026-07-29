-- 已有相对路径索引的 glob 候选
--
-- 只复用 glob 分段、转义与路径排序规则，不访问文件系统

local Parser = require('vv-utils.path_completion.parser')

local M = {}

---@param path string
---@return string, string
local function split_path(path)
  local parent, basename = path:match('^(.*)/([^/]*)$')
  return parent or '', basename or path
end

---@param parent string
---@param constraint string
---@param anchored boolean
---@return boolean
local function matches_parent(parent, constraint, anchored)
  if anchored then return parent == constraint end
  if constraint == '' then return true end
  return Parser.ends_with_path(parent, constraint)
end

---@param items vv-utils.path_completion.Item[]
---@param max_items integer
local function sort_and_limit(items, max_items)
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
end

---从调用方已有的相对路径索引生成 glob 候选
---@param input string
---@param paths string[] 相对搜索根的文件和目录路径
---@param opts? vv-utils.path_completion.IndexedGlobOpts
---@return vv-utils.path_completion.Result
function M.glob(input, paths, opts)
  opts = opts or {}
  local parsed = Parser.glob_input(input, opts.cursor)
  local source = parsed.source
  if source:match('^%.%.[/\\]') or source == '..' or Parser.is_absolute(source) then
    return { start_col = parsed.start_col, items = {} }
  end
  if Parser.has_unescaped_glob(source) then
    return { start_col = parsed.start_col, items = {} }
  end

  local anchored = source:sub(1, 2) == './' or source:sub(1, 2) == '.\\'
  local normalized_source = Parser.unescape_glob(source):gsub('\\', '/')
  if anchored then normalized_source = normalized_source:sub(3) end

  local constraint, needle = split_path(normalized_source)
  constraint = constraint:gsub('/+$', '')
  local folded_needle = needle:lower()
  ---@type fun(path: string): boolean
  local is_directory = opts.is_directory or function(_) return false end
  local items = {}

  for _, raw_path in ipairs(paths) do
    local path = raw_path:gsub('\\', '/'):gsub('^%./', ''):gsub('/+$', '')
    if path ~= '' then
      local parent, basename = split_path(path)
      local matches_prefix = basename:lower():sub(1, #folded_needle) == folded_needle
      if matches_prefix and matches_parent(parent, constraint, anchored) then
        local directory = is_directory(raw_path)
        local suffix = directory and '/' or ''
        local word = (anchored and './' or '') .. Parser.escape_glob(path) .. suffix
        items[#items + 1] = {
          word = parsed.prefix .. word,
          abbr = path .. suffix,
          kind = directory and 'Folder' or 'File',
          menu = '[path]',
        }
      end
    end
  end

  sort_and_limit(items, opts.max_items or 50)
  return { start_col = parsed.start_col, items = items }
end

---@class vv-utils.path_completion.IndexedGlobOpts
---@field cursor? integer 0-based byte 光标位置 @default #input
---@field max_items? integer 最终候选数 @default 50
---@field is_directory? fun(path: string): boolean 判断相对路径是否为目录 @default false

return M
