-- 路径工具：规范化、项目根目录、工作目录
local M = {}

-- 规范化路径（Windows 反斜杠 → 正斜杠）
function M.norm(path)
  if not path or path == "" then return "" end
  if vim.fn.has("win32") == 1 then
    return vim.fn.substitute(path, "\\", "/", "g")
  end
  return path
end

---折叠路径中间层级，保留开头与末尾指定数量的层级
---@param path string
---@param opts? vv-utils.path.CollapseMiddleOpts
---@return string
function M.collapse_middle(path, opts)
  opts = opts or {}

  if path == '' then return '' end

  local head = math.max(math.floor(opts.head or 1), 0)
  local tail = math.max(math.floor(opts.tail or 3), 0)
  local ellipsis = opts.ellipsis or '…'
  local separator = path:find('\\', 1, true) and not path:find('/', 1, true) and '\\' or '/'
  local prefix = ''
  local body = path

  if body:match('^%a:[/\\]') then
    prefix = body:sub(1, 3)
    body = body:sub(4)
  elseif body:sub(1, 1) == separator then
    prefix = separator
    body = body:gsub('^' .. vim.pesc(separator) .. '+', '')
  end

  local trailing_separator = body:sub(-1) == separator
  local segments = vim.split(body, separator, { plain = true, trimempty = true })

  if #segments <= head + tail then return path end

  local result = {}

  for index = 1, head do
    result[#result + 1] = segments[index]
  end

  result[#result + 1] = ellipsis

  for index = #segments - tail + 1, #segments do
    result[#result + 1] = segments[index]
  end

  return prefix .. table.concat(result, separator) .. (trailing_separator and separator or '')
end

-- 获取项目根目录（向上查找 .git / package.json / Cargo.toml 等标识）
function M.get_root(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local bufpath = vim.api.nvim_buf_get_name(buf)

  if bufpath == "" then
    bufpath = vim.uv.cwd()
  else
    bufpath = vim.fs.dirname(bufpath)
  end

  local root_patterns = { ".git", ".gitignore", "package.json", "Cargo.toml", "go.mod", "pyproject.toml" }
  local root = vim.fs.find(root_patterns, { path = bufpath, upward = true })[1]

  if root then
    return M.norm(vim.fs.dirname(root))
  end

  return M.norm(vim.uv.cwd())
end

-- 获取当前工作目录
function M.get_cwd()
  return M.norm(vim.uv.cwd())
end

---@class vv-utils.path.CollapseMiddleOpts
---@field head? integer 保留的开头层级数 @default 1
---@field tail? integer 保留的末尾层级数 @default 3
---@field ellipsis? string 省略标记 @default '…'
return M

