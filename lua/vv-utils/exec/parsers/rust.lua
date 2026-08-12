-- vv-utils.exec Rust 项目入口解析：通过 Cargo metadata 定位当前 target

local Common = require('vv-utils.exec.common')

local function target_kind(target)
  for _, kind in ipairs(target.kind or {}) do
    if kind == 'bin' or kind == 'example' then return kind end
  end
end

local function read_metadata(directory)
  local result = vim.system({
    'cargo',
    'metadata',
    '--no-deps',
    '--format-version',
    '1',
  }, { cwd = directory, text = true }):wait()

  if result.code ~= 0 or not result.stdout or result.stdout == '' then return nil end
  local ok, metadata = pcall(vim.json.decode, result.stdout)
  return ok and metadata or nil
end

local function find_target(metadata, path)
  path = vim.fn.resolve(vim.fn.fnamemodify(path, ':p'))

  for _, package in ipairs(metadata.packages or {}) do
    for _, target in ipairs(package.targets or {}) do
      local kind = target_kind(target)
      local source = vim.fn.resolve(vim.fn.fnamemodify(target.src_path, ':p'))

      if kind and source == path then
        return package, target, kind
      end
    end
  end
end

---@param path string
---@return { cmd: string[], runner: string, cwd: string, target: 'project' }?
return function(path)
  if vim.fn.executable('cargo') ~= 1 or not vim.uv.fs_stat(path) then return nil end

  local metadata = read_metadata(vim.fs.dirname(path))
  if not metadata then return nil end

  local package, target, kind = find_target(metadata, path)
  if not target then return nil end

  local args = { 'cargo', 'run', kind == 'example' and '--example' or '--bin', target.name }
  local features = target['required-features'] or target.required_features or {}

  if #features > 0 then
    args[#args + 1] = '--features'
    args[#args + 1] = table.concat(features, ',')
  end

  return {
    cmd = args,
    runner = 'cargo',
    cwd = Common.find_project_root(path, 'Cargo.toml') or vim.fs.dirname(package.manifest_path),
    target = 'project',
  }
end
