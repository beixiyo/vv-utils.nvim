-- git 索引：异步跑 git 命令，输出纯数据包
-- 无副作用（不订阅 autocmd、不触发 render），调用方自己做 debounce + 应用结果
--
-- 核心 API：
--   M.index(root, cb, opts)           -- git status --porcelain：状态标记（M/A/D/??/!!）
--   M.tracked(root, cb, opts)         -- git ls-files：tracked 路径集合
--   M.ignored_entries(root, cb, opts) -- git ls-files --others --ignored --directory：
--                                     --   ignored 检测（不递归进 ignored 目录，HOME-as-repo 友好）

local M = {}

local function norm(p) return vim.fs.normalize(p) end

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

-- VSCode Dark+ gitDecoration.* 调色板（所有 git 状态色的单一真相来源）
-- 通过 M.register_hl() 批量注册，vv-explorer / vv-git / 其它 vendor 统一 link 过来
local HL_SPECS = {
  VVGitAdded     = { fg = '#81b88b' }, -- staged A：灰绿
  VVGitModified  = { fg = '#e2c08d' }, -- M：黄
  VVGitDeleted   = { fg = '#c74e39' }, -- D：红
  VVGitRenamed   = { fg = '#73c991' }, -- R/C：亮绿
  VVGitUntracked = { fg = '#73c991' }, -- ?：亮绿
  VVGitConflict  = { fg = '#e4676b', bold = true },
  VVGitIgnored   = { link = 'Comment' },
}

-- 批量注册 VVGit* 高亮组（自带 default=true + ColorScheme 重挂）
---@param augroup? string  默认 'vv-utils.git.hl'
function M.register_hl(augroup)
  require('vv-utils.hl').register(augroup or 'vv-utils.git.hl', HL_SPECS)
end

-- porcelain XY → {glyph, hl}。hl 统一走 `VVGit*`（vendor-neutral）
-- 调用方需在 setup 里调一次 M.register_hl()，否则组不存在会 fallback 到 Normal
-- 不在表里的给 'M' 默认
local SYMBOLS = {
  ['??'] = { glyph = 'U', hl = 'VVGitUntracked' },
  ['A '] = { glyph = 'A', hl = 'VVGitAdded' },
  ['AM'] = { glyph = 'A', hl = 'VVGitAdded' },
  ['M '] = { glyph = 'M', hl = 'VVGitModified' },
  [' M'] = { glyph = 'M', hl = 'VVGitModified' },
  ['MM'] = { glyph = 'M', hl = 'VVGitModified' },
  ['AD'] = { glyph = 'D', hl = 'VVGitDeleted' },
  ['D '] = { glyph = 'D', hl = 'VVGitDeleted' },
  [' D'] = { glyph = 'D', hl = 'VVGitDeleted' },
  ['R '] = { glyph = 'R', hl = 'VVGitRenamed' },
  [' R'] = { glyph = 'R', hl = 'VVGitRenamed' },
  ['C '] = { glyph = 'C', hl = 'VVGitRenamed' }, -- copied，VSCode 视觉同 renamed
  [' C'] = { glyph = 'C', hl = 'VVGitRenamed' },
  ['UU'] = { glyph = '!', hl = 'VVGitConflict' },
  ['AA'] = { glyph = '!', hl = 'VVGitConflict' },
  ['DD'] = { glyph = '!', hl = 'VVGitConflict' },
}

---@param xy string?
---@return {glyph:string, hl:string}?
function M.symbol_for(xy)
  if not xy then return nil end
  return SYMBOLS[xy] or { glyph = 'M', hl = 'VVGitModified' }
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

---@class UtilsGitIndex
---@field status_map table<string,string>
---@field ignored_files table<string,boolean>
---@field ignored_dirs table<string,boolean>
---@field is_ignored fun(path:string):boolean
---@field rename_map table<string,string>

---@class UtilsGitTracked
---@field tracked_set table<string,boolean>
---@field is_tracked fun(path:string):boolean

-- 只读 .git/index 拿到所有 tracked 路径，**不**遍历工作树
-- 比 status --ignored 快一到两个数量级（HOME-as-repo 场景关键）
---@param root string
---@param cb fun(t: UtilsGitTracked?)
---@param opts? { scope?: boolean }
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

---@class UtilsGitIndexOpts
---@field untracked? 'normal'|'all'  默认 'normal'；'all' 会加 `-uall`，把 untracked 目录展开到单个文件
---@field ignored? boolean           默认 true；false 时不加 --ignored，is_ignored 始终返回 false

-- 异步索引整个仓库。
-- 非 git 仓库 / git 失败 → cb(nil)；成功 → cb(index)。
-- 回调通过 vim.schedule_wrap 已回到主线程。
---@param root string
---@param cb fun(index: UtilsGitIndex?)
---@param opts? UtilsGitIndexOpts
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
