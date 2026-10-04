-- 显式测试入口使用的依赖下载与按 commit 缓存，不参与插件运行时加载。
local M = {}

-- 独立 mini.test 仓库；统一升级此处，不追踪浮动分支。
M.mini_test_commit = 'a11d5db0c4ab0cc4d4b18b021e732fba7195f960'

--- 下载固定版本到全局缓存，已发布的版本不会被原地修改。
---@return string path mini.test 的 runtimepath
function M.ensure_mini_test()
  local cache = vim.env.VV_TEST_DEPS_CACHE
    or vim.fs.joinpath(vim.env.XDG_CACHE_HOME or vim.fs.joinpath(vim.env.HOME, '.cache'), 'nvim-test-deps')
  local parent = vim.fs.joinpath(cache, 'mini.test')
  local target = vim.fs.joinpath(parent, M.mini_test_commit)
  local module = vim.fs.joinpath(target, 'lua/mini/test.lua')
  if vim.fn.filereadable(module) == 1 then
    print('mini.test cache: ' .. target)
    return target
  end
  vim.fn.mkdir(parent, 'p')
  local staging = vim.fn.tempname()
  -- staging 必须和 target 在同一文件系统，rename 才能原子发布。
  staging = vim.fs.joinpath(parent, '.download-' .. vim.fs.basename(staging))
  vim.fn.mkdir(staging, 'p')
  local function git(args)
    local command = { 'git', '-C', staging }
    vim.list_extend(command, args)
    local result = vim.system(command, { text = true }):wait(60000)
    if result.code ~= 0 then
      error('mini.test download failed: ' .. table.concat(args, ' ') .. '\n' .. (result.stderr or ''), 0)
    end
  end
  local ok, err = pcall(function()
    print('Downloading mini.test ' .. M.mini_test_commit)
    git({ 'init', '--quiet' })
    git({ 'fetch', '--quiet', '--depth=1', 'https://github.com/nvim-mini/mini.test.git', M.mini_test_commit })
    -- 此 Git 操作只作用于新建的依赖缓存，不触及被测仓库。
    git({ 'checkout', '--quiet', '--detach', 'FETCH_HEAD' })
    assert(vim.fn.filereadable(vim.fs.joinpath(staging, 'lua/mini/test.lua')) == 1, 'download has no mini.test module')
    local published, rename_err = vim.uv.fs_rename(staging, target)
    if not published and vim.fn.filereadable(module) ~= 1 then error(rename_err, 0) end
  end)
  vim.fn.delete(staging, 'rf')
  if not ok then error(err, 0) end
  return target
end

return M
