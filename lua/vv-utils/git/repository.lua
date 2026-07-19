-- Git 仓库探测：识别工作目录类型并同步/异步查找仓库根

local M = {}

local uv = vim.uv or vim.loop

--- 探测某目录的 `.git` 属于哪类 git 工作目录（纯读文件，不起 git 进程，可用于热路径/递归扫描）。
--- 普通 / 主仓库的 `.git` 是**目录**；linked worktree 与 submodule 的 `.git` 都是**文件**
--- （内容 `gitdir: <path>`），据 gitdir 路径里的 `/worktrees/` vs `/modules/` 区分二者。
---@param dir string  目录路径（绝对或相对）
---@return 'repo'|'worktree'|'submodule'|'linked'|nil kind
---   'repo'      → `.git` 是目录（普通仓库 / 主 worktree）
---   'worktree'  → linked worktree（gitdir 指向 `.../worktrees/...`）
---   'submodule' → submodule 工作树（gitdir 指向 `.../modules/...`）
---   'linked'    → `.git` 是文件但无法归类（罕见）
---   nil         → 该目录下无 `.git`
function M.git_dir_kind(dir)
  local dotgit = dir .. '/.git'
  local st = uv.fs_lstat(dotgit)
  if not st then return nil end
  if st.type == 'directory' then return 'repo' end
  if st.type ~= 'file' then return nil end

  -- `.git` 是文件：读 `gitdir: <path>` 一行判类（文件极小，几十字节）
  local fd = uv.fs_open(dotgit, 'r', 438)
  if not fd then return 'linked' end
  local data = uv.fs_read(fd, st.size > 0 and st.size or 4096, 0) or ''
  uv.fs_close(fd)

  local gitdir = data:match('gitdir:%s*([^\n]+)')
  if not gitdir then return 'linked' end
  if gitdir:find('/worktrees/', 1, true) then return 'worktree' end
  if gitdir:find('/modules/', 1, true) then return 'submodule' end
  return 'linked'
end

--- 是否为 linked worktree（`git_dir_kind` == 'worktree' 的便捷封装）
---@param dir string
---@return boolean
function M.is_linked_worktree(dir)
  return M.git_dir_kind(dir) == 'worktree'
end

--- 探测 cwd 所在 git 仓库根（rev-parse --show-toplevel）。同步版（会阻塞，勿用于热路径）。
---@param cwd? string  默认 vim.fn.getcwd()
---@return string? root  规范化绝对路径；非 git 仓库 / 出错返回 nil
function M.root(cwd)
  cwd = cwd or vim.fn.getcwd()
  local out = vim.fn.systemlist({ 'git', '-C', cwd, 'rev-parse', '--show-toplevel' })
  if vim.v.shell_error ~= 0 or not out[1] or out[1] == '' then return nil end
  return vim.fs.normalize(out[1])
end

--- 异步版：不阻塞主循环，结果经 cb 回传。用于热路径（statuscolumn 等）
---@param cwd string
---@param cb fun(root: string?)  非 git 仓库 / 出错回传 nil
function M.root_async(cwd, cb)
  vim.system(
    { 'git', '-C', cwd, 'rev-parse', '--show-toplevel' },
    { text = true },
    vim.schedule_wrap(function(res)
      if res.code ~= 0 or not res.stdout or res.stdout == '' then
        cb(nil)
      else
        cb(vim.fs.normalize(vim.trim(res.stdout)))
      end
    end)
  )
end

return M
