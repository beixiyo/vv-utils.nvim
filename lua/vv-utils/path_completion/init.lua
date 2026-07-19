-- 路径补全领域入口
--
-- 只暴露 glob / directory 两种补全能力；语法解析、文件扫描和候选生成由子模块负责

local Candidates = require('vv-utils.path_completion.candidates')
local Parser = require('vv-utils.path_completion.parser')

local uv = vim.uv

local M = {}

local DEFAULT_TIMEOUT_MS = 250

---@param input string
---@param opts? vv-utils.path_completion.GlobOpts
---@return vv-utils.path_completion.Result
function M.glob(input, opts)
  opts = opts or {}
  input = input or ''
  local cursor = math.max(0, math.min(opts.cursor or #input, #input))
  local start_col = Parser.glob_segment_start(input, cursor)
  local source = input:sub(start_col + 1, cursor)
  local prefix = ''

  if source:sub(1, 1) == '!' then
    prefix = '!'
    source = source:sub(2)
  end

  if source:match('^%.%./') or source == '..' or Parser.is_absolute(source) then
    return { start_col = start_col, items = {} }
  end

  local items = Candidates.complete(source, opts.cwd or uv.cwd(), {
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
  return {
    start_col = start_col,
    items = Candidates.complete(source, opts.cwd or uv.cwd(), {
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
