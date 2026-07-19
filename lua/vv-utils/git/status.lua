-- Git 状态索引：解析 porcelain 输出并异步读取 tracked、ignored 与工作树状态

local M = {}

local function norm(path) return vim.fs.normalize(path) end

-- porcelain v1 -z 格式：`XY path\0`（rename/copy 额外跟一个旧路径 `old\0`）
-- 目录级 ignored 以 '/' 结尾，单独进 ignored_dirs
---@param data string
---@param root string
---@return table<string,string> status_map, table<string,boolean> ignored_files, table<string,boolean> ignored_dirs, table<string,string> rename_map
function M.parse_porcelain_z(data, root)
  local status_map = {}
  local ignored_files = {}
  local ignored_dirs = {}
  local rename_map = {}
  local entries = vim.split(data or '', '\0', { plain = true })
  local i = 1
  while i <= #entries do
    local entry = entries[i]
    if entry == '' then
      i = i + 1
    else
      local xy = entry:sub(1, 2)
      local rest = entry:sub(4)
      local first = xy:sub(1, 1)
      local old_abs

      if first == 'R' or first == 'C' then
        local old_rest = entries[i + 1]
        if old_rest and old_rest ~= '' then
          old_abs = norm(root .. '/' .. old_rest)
        end
        i = i + 1
      end

      -- vim.fs.normalize 已经去掉了尾斜杠，不要再 sub(1,-2)
      local abs = norm(root .. '/' .. rest)
      if old_abs then
        rename_map[abs] = old_abs
      end

      if rest:sub(-1) == '/' then
        if xy == '!!' then
          ignored_dirs[abs] = true
        else
          status_map[abs] = xy  -- untracked 目录（?? dir/）作为整体节点保留
        end
      elseif xy == '!!' then
        ignored_files[abs] = true
      else
        status_map[abs] = xy
      end
      i = i + 1
    end
  end
  return status_map, ignored_files, ignored_dirs, rename_map
end

-- 构造 is_ignored(path)：文件直接命中 or 自身是 ignored 目录 or 任一祖先目录命中
---@param files table<string,boolean>
---@param dirs table<string,boolean>
---@return fun(path:string):boolean
function M.make_is_ignored(files, dirs)
  return function(path)
    if files[path] then return true end
    if dirs[path] then return true end -- node_modules 自身
    local cur = path
    while cur ~= '' and cur ~= '/' do
      local parent = vim.fs.dirname(cur)
      if parent == cur then break end
      if dirs[parent] then return true end
      cur = parent
    end
    return false
  end
end

-- ls-files 输出构造 tracked_set：文件 + 每层祖先目录都标 true
-- 这样 `.github/workflows/ci.yml` 被跟踪时 `.github/` 也算，filter 层能整条放行
---@param data string  ls-files -z 的 NUL 分隔输出
---@param root string  规范化后的仓库根
---@return table<string,boolean>
local function build_tracked_set(data, root)
  local set = {}
  if not data or data == '' then return set end
  for rel in (data .. '\0'):gmatch('([^%z]+)%z') do
    local abs = norm(root .. '/' .. rel)
    set[abs] = true
    local cur = vim.fs.dirname(abs)
    while cur and cur ~= '' and cur ~= root do
      if set[cur] then break end
      set[cur] = true
      local parent = vim.fs.dirname(cur)
      if parent == cur then break end
      cur = parent
    end
  end
  return set
end

---@class vv-utils.git.Index
---@field status_map table<string,string> 路径到 porcelain XY 状态的映射 @default {}
---@field ignored_files table<string,boolean> 被忽略文件集合 @default {}
---@field ignored_dirs table<string,boolean> 被忽略目录集合 @default {}
---@field is_ignored fun(path:string):boolean 忽略状态查询函数 @default none
---@field rename_map table<string,string> 新路径到旧路径的重命名映射 @default {}

---@class vv-utils.git.Tracked
---@field tracked_set table<string,boolean> 已跟踪路径集合 @default {}
---@field is_tracked fun(path:string):boolean 跟踪状态查询函数 @default none

---@class vv-utils.git.TrackedOpts
---@field scope? boolean 是否仅查询 root 当前路径范围 @default false

-- 只读 .git/index 拿到所有 tracked 路径，**不**遍历工作树
-- 比 status --ignored 快一到两个数量级（HOME-as-repo 场景关键）
---@param root string
---@param cb fun(t: vv-utils.git.Tracked?)
---@param opts? vv-utils.git.TrackedOpts
function M.tracked(root, cb, opts)
  if not root or root == '' then cb(nil); return end
  root = norm(root)
  local cmd = { 'git', '-C', root, 'ls-files', '-z' }
  if opts and opts.scope then
    table.insert(cmd, '--')
    table.insert(cmd, '.')
  end
  vim.system(
    cmd,
    { text = false },
    vim.schedule_wrap(function(st)
      if st.code ~= 0 then cb(nil); return end
      local set = build_tracked_set(st.stdout, root)
      cb({
        tracked_set = set,
        is_tracked = function(path) return set[path] == true end,
      })
    end)
  )
end

---@class vv-utils.git.IndexOpts
---@field untracked? 'normal'|'all' 是否把未跟踪目录展开到文件粒度 @default 'normal'
---@field ignored? boolean 是否查询 ignored 路径 @default true
---@field scope? boolean 是否仅查询 root 当前路径范围 @default false

-- 异步索引整个仓库。
-- 非 git 仓库 / git 失败 → cb(nil)；成功 → cb(index)。
-- 回调通过 vim.schedule_wrap 已回到主线程。
---@param root string
---@param cb fun(index: vv-utils.git.Index?)
---@param opts? vv-utils.git.IndexOpts
function M.index(root, cb, opts)
  if not root or root == '' then cb(nil); return end
  root = norm(root)
  local args = { 'git', '-C', root, 'status', '--porcelain=v1', '-z' }
  if not (opts and opts.ignored == false) then
    table.insert(args, '--ignored')
  end
  if opts and opts.untracked == 'all' then
    table.insert(args, '-uall')
  end
  -- scope = true → 只扫 -C 目录下的文件（HOME-as-repo 场景关键：避免扫整个 ~）
  if opts and opts.scope then
    table.insert(args, '--')
    table.insert(args, '.')
  end
  vim.system(args, { text = false }, vim.schedule_wrap(function(st)
    if st.code ~= 0 then cb(nil); return end
    local status_map, ifiles, idirs, rename_map = M.parse_porcelain_z(st.stdout, root)
    cb({
      status_map = status_map,
      ignored_files = ifiles,
      ignored_dirs = idirs,
      is_ignored = M.make_is_ignored(ifiles, idirs),
      rename_map = rename_map,
    })
  end))
end

-- 列出所有 untracked + ignored 的路径。走 `git ls-files --others --ignored --directory`：
--   * `--others`：只看 untracked（tracked 文件天然排除，无需手动过滤）
--   * `--ignored --exclude-standard`：只列被 .gitignore 命中的
--   * `--directory`：ignored 目录作为整体报告，**不递归进去**
--     （这是 `git status --ignored` 慢的根因——它递归进 Downloads/Library 等巨目录）
-- 语义完全等价于 `git status --ignored` 里的 `!!` 条目，但快几个数量级。
---@param root string  CWD for git（-C 参数）
---@param cb fun(ignored_files: table<string,boolean>, ignored_dirs: table<string,boolean>)
---@param opts? { scope?: boolean }
function M.ignored_entries(root, cb, opts)
  if not root or root == '' then cb({}, {}); return end
  root = norm(root)
  local cmd = { 'git', '-C', root, 'ls-files', '--others', '--ignored', '--exclude-standard', '--directory', '-z' }
  if opts and opts.scope then
    table.insert(cmd, '--')
    table.insert(cmd, '.')
  end
  vim.system(cmd, { text = false }, vim.schedule_wrap(function(st)
    local ifiles, idirs = {}, {}
    if st.code ~= 0 then cb(ifiles, idirs); return end
    if not st.stdout or #st.stdout == 0 then cb(ifiles, idirs); return end
    for rel in (st.stdout .. '\0'):gmatch('([^%z]+)%z') do
      -- --directory 输出的目录以 '/' 结尾
      if rel:sub(-1) == '/' then
        idirs[norm(root .. '/' .. rel)] = true
      else
        ifiles[norm(root .. '/' .. rel)] = true
      end
    end
    cb(ifiles, idirs)
  end))
end

return M
