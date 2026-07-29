-- 路径候选扫描
--
-- 只负责从文件系统或 fd 收集、过滤和排序原始路径，不生成 CompleteItem

local Parser = require('vv-utils.path_completion.parser')

local uv = vim.uv

local M = {}
local ASYNC_BATCH_SIZE = 128

---@param timer? uv.uv_timer_t
local function close_timer(timer)
  if not timer or timer:is_closing() then return end
  timer:stop()
  timer:close()
end

---@param callback fun(matches: vv-utils.path_completion.Match[])
---@return fun() cancel
local function schedule_empty(callback)
  local cancelled = false
  vim.schedule(function()
    if not cancelled then callback({}) end
  end)
  return function() cancelled = true end
end

---@class vv-utils.path_completion.Match
---@field value string
---@field directory boolean

---@param path string
---@return boolean
local function is_directory(path)
  local stat = uv.fs_stat(path)
  return stat ~= nil and stat.type == 'directory'
end

---@param matches vv-utils.path_completion.Match[]
---@param max_items integer
---@return vv-utils.path_completion.Match[]
local function sort_direct(matches, max_items)
  table.sort(matches, function(left, right)
    if left.directory ~= right.directory then return left.directory end
    return left.value:lower() < right.value:lower()
  end)

  while #matches > max_items do table.remove(matches) end
  return matches
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

  return sort_direct(matches, opts.max_items)
end

---分批扫描当前目录，避免大目录一次占满主线程
---@param scan_dir string
---@param needle string
---@param opts { directories_only: boolean, max_items: integer, timeout_ms: integer }
---@param callback fun(matches: vv-utils.path_completion.Match[])
---@return fun() cancel
function M.direct_async(scan_dir, needle, opts, callback)
  local handle = uv.fs_scandir(scan_dir)
  if not handle then return schedule_empty(callback) end

  local cancelled = false
  local finished = false
  local matches = {}
  local pending_stats = 0
  local scan_done = false
  local folded_needle = needle:lower()
  local timer = uv.new_timer()

  local function finish()
    if cancelled or finished or not scan_done or pending_stats > 0 then return end
    finished = true
    close_timer(timer)
    callback(sort_direct(matches, opts.max_items))
  end

  local function add(name, directory)
    if directory or not opts.directories_only then
      matches[#matches + 1] = { value = name, directory = directory }
    end
  end

  local function step()
    if cancelled or finished then return end

    for _ = 1, ASYNC_BATCH_SIZE do
      local name, kind = uv.fs_scandir_next(handle)
      if not name then
        scan_done = true
        finish()
        return
      end

      local hidden = name:sub(1, 1) == '.'
      local matches_prefix = name:lower():sub(1, #folded_needle) == folded_needle
      if matches_prefix and (not hidden or needle:sub(1, 1) == '.') then
        if kind == 'link' then
          pending_stats = pending_stats + 1
          uv.fs_stat(vim.fs.joinpath(scan_dir, name), function(_, stat)
            pending_stats = pending_stats - 1
            if not cancelled then add(name, stat ~= nil and stat.type == 'directory') end
            finish()
          end)
        else
          add(name, kind == 'directory')
        end
      end
    end

    vim.schedule(step)
  end

  if timer then
    timer:start(opts.timeout_ms, 0, vim.schedule_wrap(function()
      if finished then return end
      cancelled = true
      close_timer(timer)
      callback({})
    end))
  end
  vim.schedule(step)

  return function()
    if cancelled or finished then return end
    cancelled = true
    close_timer(timer)
  end
end

local REGEX_SPECIAL = {
  ['\\'] = true,
  ['.'] = true,
  ['^'] = true,
  ['$'] = true,
  ['|'] = true,
  ['?'] = true,
  ['*'] = true,
  ['+'] = true,
  ['('] = true,
  [')'] = true,
  ['['] = true,
  [']'] = true,
  ['{'] = true,
  ['}'] = true,
}

---@param value string
---@return string
local function escape_regex(value)
  local escaped = {}
  for index = 1, #value do
    local char = value:sub(index, index)
    escaped[#escaped + 1] = REGEX_SPECIAL[char] and ('\\' .. char) or char
  end
  return table.concat(escaped)
end

---@param value string
---@return boolean
local function has_hidden_component(value)
  return value:match('^%.') ~= nil or value:match('[/\\]%.') ~= nil
end

---@param needle string
---@param parent string
---@param opts { directories_only: boolean, scan_max_items: integer }
---@return string[]
local function descendant_args(needle, parent, opts)
  parent = Parser.strip_relative_prefix(parent):gsub('\\', '/')
  local path_prefix = parent == '' and '(?:^|/)' or ('(?:^|/)' .. escape_regex(parent) .. '/')
  local pattern = path_prefix .. escape_regex(needle) .. '[^/]*$'
  local args = {
    'fd',
    '--full-path',
    '--ignore-case',
    '--color',
    'never',
    '--print0',
    '--strip-cwd-prefix=always',
    '--path-separator',
    '/',
    '--type',
    'directory',
  }
  if not opts.directories_only then vim.list_extend(args, { '--type', 'file' }) end
  if has_hidden_component(parent) or needle:sub(1, 1) == '.' then args[#args + 1] = '--hidden' end

  vim.list_extend(args, { '--max-results', tostring(opts.scan_max_items), '--', pattern })
  return args
end

---@param output string
---@param opts { directories_only: boolean, max_items: integer }
---@return vv-utils.path_completion.Match[]
local function parse_descendants(output, opts)
  local matches = {}
  for raw in (output .. '\0'):gmatch('([^%z]+)%z') do
    raw = raw:gsub('\\', '/')
    local directory = raw:sub(-1) == '/'
    local relative = Parser.strip_relative_prefix(raw)
    if relative ~= '' and (directory or not opts.directories_only) then
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

---@param needle string
---@param parent string
---@param cwd string
---@param opts { directories_only: boolean, max_items: integer, scan_max_items: integer, timeout_ms: integer }
---@return vv-utils.path_completion.Match[]
function M.descendants(needle, parent, cwd, opts)
  if needle == '' or vim.fn.executable('fd') ~= 1 or not is_directory(cwd) then return {} end

  local ok, result = pcall(function()
    return vim.system(descendant_args(needle, parent, opts), { cwd = cwd, text = false }):wait(opts.timeout_ms)
  end)
  if not ok or result.code ~= 0 or not result.stdout then return {} end
  return parse_descendants(result.stdout, opts)
end

---异步递归扫描；fd 先按最终 basename/parent 约束过滤，再应用原始结果预算
---@param needle string
---@param parent string
---@param cwd string
---@param opts { directories_only: boolean, max_items: integer, scan_max_items: integer, timeout_ms: integer }
---@param callback fun(matches: vv-utils.path_completion.Match[])
---@return fun() cancel
function M.descendants_async(needle, parent, cwd, opts, callback)
  if needle == '' or vim.fn.executable('fd') ~= 1 or not is_directory(cwd) then
    return schedule_empty(callback)
  end

  local cancelled = false
  local finished = false
  local process
  local timer = uv.new_timer()

  local function finish(matches)
    if cancelled or finished then return end
    finished = true
    close_timer(timer)
    callback(matches)
  end

  process = vim.system(
    descendant_args(needle, parent, opts),
    { cwd = cwd, text = false },
    vim.schedule_wrap(function(result)
      if result.code ~= 0 or not result.stdout then
        finish({})
      else
        finish(parse_descendants(result.stdout, opts))
      end
    end)
  )

  if timer then
    timer:start(opts.timeout_ms, 0, vim.schedule_wrap(function()
      if finished then return end
      cancelled = true
      close_timer(timer)
      if process then pcall(process.kill, process, 15) end
      callback({})
    end))
  end

  return function()
    if cancelled or finished then return end
    cancelled = true
    close_timer(timer)
    if process then pcall(process.kill, process, 15) end
  end
end

return M
