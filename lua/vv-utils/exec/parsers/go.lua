-- vv-utils.exec Go 项目入口解析：识别 main package，构建规则交给 Go 工具链

local Common = require('vv-utils.exec.common')
local Source = require('vv-utils.exec.source')

local comments = { line = { '//' }, block = { { open = '/*', close = '*/' } } }

local function read_package(path)
  local file = io.open(path, 'r')
  if not file then return nil end
  local source = file:read('*a') or ''
  file:close()

  local index = Source.skip_trivia(source, 1, comments)
  if not index then return nil end

  local keyword
  keyword, index = Source.read_identifier(source, index)
  if keyword ~= 'package' then return nil end

  index = Source.skip_trivia(source, index, comments)
  if not index then return nil end
  return Source.read_identifier(source, index)
end

---@param path string
---@return { cmd: string[], runner: string, cwd: string, target: 'project' }?
return function(path)
  if vim.fn.executable('go') ~= 1 or read_package(path) ~= 'main' then return nil end

  local directory = vim.fs.dirname(path)
  if Common.find_project_root(path, 'go.mod') then
    return { cmd = { 'go', 'run', '.' }, runner = 'go', cwd = directory, target = 'project' }
  end

  return { cmd = { 'go', 'run', path }, runner = 'go', cwd = directory, target = 'project' }
end
