-- VS Code 风格的搜索 glob 解析与编译
--
-- 用户输入是搜索框简写，不是直接传给 ripgrep 的 glob：
--   core/src    -> **/core/src + **/core/src/**
--   ./core/src  -> /core/src + /core/src/**
--
-- 同时生成“路径本体”和“目录后代”，避免通过扩展名猜文件/目录

local M = {}

---@param char string?
---@return boolean
local function is_escape_target(char)
  return char ~= nil and char:match('[,{}%[%]*?!\\]') ~= nil
end

---@param raw string
---@return string
local function normalize_separators(raw)
  local chars = {}
  local index = 1

  while index <= #raw do
    local char = raw:sub(index, index)
    local next_char = index < #raw and raw:sub(index + 1, index + 1) or nil

    if char == '\\' and is_escape_target(next_char) then
      chars[#chars + 1] = char
    elseif char == '\\' then
      chars[#chars + 1] = '/'
    else
      chars[#chars + 1] = char
    end

    index = index + 1
  end

  return table.concat(chars)
end

---@param patterns string[]
---@param value string
local function append_unique(patterns, value)
  if value == '' then return end
  for _, pattern in ipairs(patterns) do
    if pattern == value then return end
  end
  patterns[#patterns + 1] = value
end

---@param pattern string
---@return string
local function collapse_globstars(pattern)
  local previous
  repeat
    previous = pattern
    pattern = pattern:gsub('%*%*/%*%*/', '**/')
    pattern = pattern:gsub('%*%*/%*%*$', '**')
  until pattern == previous
  return pattern
end

---按顶层逗号拆分 glob 列表，保留 brace、字符类与转义逗号
---@param raw string?
---@return string[]? patterns
---@return string? error
function M.split(raw)
  if not raw or vim.trim(raw) == '' then return {}, nil end

  local patterns = {}
  local part = {}
  local brace_depth = 0
  local in_class = false
  local index = 1

  local function push()
    local value = vim.trim(table.concat(part))
    if value ~= '' then patterns[#patterns + 1] = value end
    part = {}
  end

  while index <= #raw do
    local char = raw:sub(index, index)
    local next_char = index < #raw and raw:sub(index + 1, index + 1) or nil

    if char == '\\' and is_escape_target(next_char) then
      part[#part + 1] = char
      part[#part + 1] = next_char
      index = index + 2
    elseif char == '[' and not in_class then
      in_class = true
      part[#part + 1] = char
      index = index + 1
    elseif char == ']' and in_class then
      in_class = false
      part[#part + 1] = char
      index = index + 1
    elseif char == '{' and not in_class then
      brace_depth = brace_depth + 1
      part[#part + 1] = char
      index = index + 1
    elseif char == '}' and not in_class then
      if brace_depth == 0 then return nil, 'unexpected } in glob pattern' end
      brace_depth = brace_depth - 1
      part[#part + 1] = char
      index = index + 1
    elseif char == ',' and brace_depth == 0 and not in_class then
      push()
      index = index + 1
    else
      part[#part + 1] = char
      index = index + 1
    end
  end

  if brace_depth > 0 then return nil, 'unclosed { in glob pattern' end
  if in_class then return nil, 'unclosed [ in glob pattern' end

  push()
  return patterns, nil
end

---把一条 VS Code 风格搜索简写编译为 ripgrep glob
---@param source string
---@param opts? vv-utils.glob.RgCompileOpts
---@return string[]? patterns
---@return string? error
function M.compile_rg(source, opts)
  opts = opts or {}
  source = vim.trim(source or '')
  if source == '' then return {}, nil end

  local negated = opts.negate == true
  if source:sub(1, 1) == '!' then
    negated = true
    source = source:sub(2)
  end

  local body = normalize_separators(vim.trim(source))
  local root_relative = body:sub(1, 2) == './'
  if root_relative then body = body:sub(3) end

  if body:match('^%.%./') or body == '..' then
    return nil, 'parent search paths are not supported; change Cwd instead'
  end
  if body:sub(1, 1) == '/' or body:match('^%a:/') then
    return nil, 'absolute search paths are not supported; change Cwd instead'
  end

  body = body:gsub('/+$', '')
  if body == '' then body = '**' end
  if not root_relative and body:sub(1, 1) == '.' then body = '*' .. body end

  local prefix = negated and '!' or ''
  local patterns = {}

  if root_relative then
    local anchored = body == '**' and '/**' or '/' .. body
    append_unique(patterns, prefix .. collapse_globstars(anchored .. '/**'))
    append_unique(patterns, prefix .. collapse_globstars(anchored))
  else
    append_unique(patterns, prefix .. collapse_globstars('**/' .. body .. '/**'))
    append_unique(patterns, prefix .. collapse_globstars('**/' .. body))
  end

  return patterns, nil
end

---拆分并编译一组 glob，保持用户输入顺序
---@param raw string?
---@param opts? vv-utils.glob.RgCompileOpts
---@return string[]? patterns
---@return string? error
function M.compile_rg_list(raw, opts)
  local sources, split_error = M.split(raw)
  if not sources then return nil, split_error end

  local patterns = {}
  for _, source in ipairs(sources) do
    local compiled, compile_error = M.compile_rg(source, opts)
    if not compiled then return nil, compile_error end
    vim.list_extend(patterns, compiled)
  end

  return patterns, nil
end

---@class vv-utils.glob.RgCompileOpts
---@field negate? boolean 强制生成排除 pattern @default false

return M
