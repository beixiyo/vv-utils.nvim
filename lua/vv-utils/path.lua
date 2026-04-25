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

return M
