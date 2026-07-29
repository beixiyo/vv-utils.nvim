-- 路径补全领域入口
--
-- 暴露 glob / directory 补全；语法解析、文件扫描和索引候选生成由子模块负责

local Candidates = require('vv-utils.path_completion.candidates')
local Indexed = require('vv-utils.path_completion.indexed')
local Parser = require('vv-utils.path_completion.parser')

local uv = vim.uv

local M = {}

local DEFAULT_TIMEOUT_MS = 250
local DEFAULT_MAX_ITEMS = 50
local DEFAULT_SCAN_MAX_ITEMS = 1000

---@return string
local function current_cwd()
  return uv.cwd() or vim.fn.getcwd()
end

---@param opts? vv-utils.path_completion.GlobOpts|vv-utils.path_completion.DirectoryOpts
---@param recursive boolean
---@return table
local function candidate_opts(opts, recursive)
  opts = opts or {}
  return {
    directories_only = not recursive,
    glob = recursive,
    max_items = opts.max_items or DEFAULT_MAX_ITEMS,
    scan_max_items = opts.scan_max_items or DEFAULT_SCAN_MAX_ITEMS,
    recursive = recursive,
    timeout_ms = opts.timeout_ms or DEFAULT_TIMEOUT_MS,
  }
end

---@param input string
---@param opts? vv-utils.path_completion.GlobOpts
---@return vv-utils.path_completion.Result
function M.glob(input, opts)
  opts = opts or {}
  local parsed = Parser.glob_input(input, opts.cursor)

  if parsed.source:match('^%.%./') or parsed.source == '..' or Parser.is_absolute(parsed.source) then
    return { start_col = parsed.start_col, items = {} }
  end

  local items = Candidates.complete(parsed.source, opts.cwd or current_cwd(), candidate_opts(opts, true))
  if parsed.prefix ~= '' then
    for _, item in ipairs(items) do item.word = parsed.prefix .. item.word end
  end

  return { start_col = parsed.start_col, items = items }
end

---异步生成 glob 路径候选，返回幂等 cancel
---@param input string
---@param opts? vv-utils.path_completion.GlobOpts
---@param callback fun(result: vv-utils.path_completion.Result)
---@return fun() cancel
function M.glob_async(input, opts, callback)
  opts = opts or {}
  local parsed = Parser.glob_input(input, opts.cursor)

  if parsed.source:match('^%.%./') or parsed.source == '..' or Parser.is_absolute(parsed.source) then
    local cancelled = false
    vim.schedule(function()
      if not cancelled then callback({ start_col = parsed.start_col, items = {} }) end
    end)
    return function() cancelled = true end
  end

  return Candidates.complete_async(parsed.source, opts.cwd or current_cwd(), candidate_opts(opts, true), function(items)
    if parsed.prefix ~= '' then
      for _, item in ipairs(items) do item.word = parsed.prefix .. item.word end
    end
    callback({ start_col = parsed.start_col, items = items })
  end)
end

---从调用方已有的相对路径索引生成 glob 候选，不访问文件系统
---@param input string
---@param paths string[]
---@param opts? vv-utils.path_completion.IndexedGlobOpts
---@return vv-utils.path_completion.Result
function M.glob_from_paths(input, paths, opts)
  return Indexed.glob(input, paths, opts)
end

---@param input string?
---@param opts? vv-utils.path_completion.DirectoryOpts
---@return string, integer, integer, string
local function directory_input(input, opts)
  input = input or ''
  opts = opts or {}
  local cursor = math.max(0, math.min(opts.cursor or #input, #input))
  local start_col = 0
  while start_col < cursor and input:sub(start_col + 1, start_col + 1):match('%s') do
    start_col = start_col + 1
  end
  return input, cursor, start_col, input:sub(start_col + 1, cursor)
end

---@param input string
---@param opts? vv-utils.path_completion.DirectoryOpts
---@return vv-utils.path_completion.Result
function M.directory(input, opts)
  opts = opts or {}
  local _, _, start_col, source = directory_input(input, opts)
  return {
    start_col = start_col,
    items = Candidates.complete(source, opts.cwd or current_cwd(), candidate_opts(opts, false)),
  }
end

---异步生成纯目录候选，返回幂等 cancel
---@param input string
---@param opts? vv-utils.path_completion.DirectoryOpts
---@param callback fun(result: vv-utils.path_completion.Result)
---@return fun() cancel
function M.directory_async(input, opts, callback)
  opts = opts or {}
  local _, _, start_col, source = directory_input(input, opts)
  return Candidates.complete_async(source, opts.cwd or current_cwd(), candidate_opts(opts, false), function(items)
    callback({ start_col = start_col, items = items })
  end)
end

---@class vv-utils.path_completion.GlobOpts
---@field cwd? string 候选路径的搜索根 @default vim.uv.cwd()
---@field cursor? integer 0-based byte 光标位置 @default #input
---@field max_items? integer 最终候选数 @default 50
---@field scan_max_items? integer 递归扫描原始结果上限 @default 1000
---@field timeout_ms? integer 递归路径查询超时毫秒数 @default 250

---@class vv-utils.path_completion.DirectoryOpts
---@field cwd? string 相对路径的搜索根 @default vim.uv.cwd()
---@field cursor? integer 0-based byte 光标位置 @default #input
---@field max_items? integer 最终候选数 @default 50
---@field scan_max_items? integer 递归扫描原始结果上限 @default 1000
---@field timeout_ms? integer 路径查询超时毫秒数 @default 250

---@class vv-utils.path_completion.Result: VVCompletionResult
---@field items vv-utils.path_completion.Item[] 路径候选 @default {}

return M
