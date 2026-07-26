--- 路径工具：规范化、项目根目录、工作目录
local M = {}

local fallback_markers = {
  'package.json',
  'pnpm-workspace.yaml',
  'pnpm-lock.yaml',
  'yarn.lock',
  'package-lock.json',
  'bun.lock',
  'bun.lockb',
  'deno.json',
  'deno.jsonc',
  'Cargo.toml',
  'go.mod',
  'pyproject.toml',
  'uv.lock',
  'poetry.lock',
  'Pipfile',
  'requirements.txt',
  'pom.xml',
  'build.gradle',
  'build.gradle.kts',
  'settings.gradle',
  'settings.gradle.kts',
  'composer.json',
  'Gemfile',
  'mix.exs',
  'Package.swift',
  'CMakeLists.txt',
}

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

local function start_directory(path)
  local absolute = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
  local stat = vim.uv.fs_stat(absolute)
  if stat and stat.type == 'directory' then return absolute end
  return vim.fs.dirname(absolute)
end

local function marker_root(directory, markers)
  local marker = vim.fs.find(markers, { path = directory, upward = true })[1]
  return marker and M.norm(vim.fs.dirname(marker)) or nil
end

---从文件或目录推断项目根。优先最近的 Git 工作树，再回退到最近的语言或构建 manifest
---@param path string 文件或目录路径
---@param opts? vv-utils.path.FindRootOpts
---@return string? root 未命中时返回 nil
function M.find_root(path, opts)
  if not path or path == '' then return nil end

  local directory = start_directory(path)
  local git_root = marker_root(directory, { '.git' })
  if git_root then return git_root end

  return marker_root(directory, opts and opts.markers or fallback_markers)
end

---获取 buffer 所在项目根。未命中时保留当前工作目录作为兼容回退
---@param buf? integer buffer 编号，默认当前 buffer
---@return string root
function M.get_root(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buf)
  if path == '' then path = vim.uv.cwd() or vim.fn.getcwd() end

  return M.find_root(path) or M.norm(vim.uv.cwd() or vim.fn.getcwd())
end

-- 获取当前工作目录
function M.get_cwd()
  return M.norm(vim.uv.cwd() or vim.fn.getcwd())
end

---@class vv-utils.path.CollapseMiddleOpts
---@field head? integer 保留的开头层级数 @default 1
---@field tail? integer 保留的末尾层级数 @default 3
---@field ellipsis? string 省略标记 @default '…'

---@class vv-utils.path.FindRootOpts
---@field markers? string[] Git 未命中时向上搜索的 manifest 名称 @default 内置跨语言 manifest 列表
return M
