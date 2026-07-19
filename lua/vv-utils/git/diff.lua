-- Git 行级差异：解析 unified diff、映射 staged 坐标并异步读取文件差异

local M = {}

local repository = require('vv-utils.git.repository')

local function norm(path) return vim.fs.normalize(path) end

-- unified diff hunk header -> 行级标记。
-- 默认投影 new 侧，规则与 vv-statuscol 当前 git 槽一致：
--   old=0, new>0  -> 纯新增：new_start..new_start+new_len-1 标 A
--   new=0, old>0  -> 纯删除：在 max(new_start, 1) 标 D
--   old>0, new>0  -> 修改：重叠行标 C，额外新增行标 A，额外删除合并到最后一个 C
-- old 侧用于显示 HEAD 等基准内容：纯删除覆盖原始行，修改按 old 行号投影。
---@param diff string
---@param side? 'new'|'old'  投影到 diff 哪一侧 @default 'new'
---@return table<integer, 'A'|'C'|'D'>
function M.parse_diff_lines(diff, side)
  local out = {}
  side = side or 'new'

  for line in (diff or ''):gmatch('[^\n]+') do
    local old_start_s, old_len_s, new_start_s, new_len_s =
      line:match('^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@')
    if new_start_s then
      local old_start = tonumber(old_start_s) or 0
      local old_len = tonumber(old_len_s == '' and '1' or old_len_s) or 1
      local new_start = tonumber(new_start_s) or 0
      local new_len = tonumber(new_len_s == '' and '1' or new_len_s) or 1

      if side == 'old' then
        if old_len == 0 and new_len > 0 then
          out[math.max(old_start, 1)] = 'A'
        elseif old_len > 0 and new_len == 0 then
          for i = old_start, old_start + old_len - 1 do out[i] = 'D' end
        elseif old_len > 0 and new_len > 0 then
          local overlap = math.min(old_len, new_len)
          for i = old_start, old_start + overlap - 1 do out[i] = 'C' end
          if old_len > new_len then
            for i = old_start + overlap, old_start + old_len - 1 do out[i] = 'D' end
          end
        end
      else
        if new_len == 0 and old_len > 0 then
          out[math.max(new_start, 1)] = 'D'
        elseif new_len > 0 and old_len == 0 then
          for i = new_start, new_start + new_len - 1 do out[i] = 'A' end
        elseif new_len > 0 and old_len > 0 then
          local overlap = math.min(old_len, new_len)
          for i = new_start, new_start + overlap - 1 do out[i] = 'C' end
          if new_len > old_len then
            for i = new_start + overlap, new_start + new_len - 1 do out[i] = 'A' end
          end
        end
      end
    end
  end

  return out
end

---@class vv-utils.git.DiffHunk
---@field old_start integer 旧侧起始行 @default 0
---@field old_len integer 旧侧行数 @default 0
---@field new_start integer 新侧起始行 @default 0
---@field new_len integer 新侧行数 @default 0

---解析 unified diff hunk，用于在 index 与 worktree 之间映射行号
---@param diff string
---@return vv-utils.git.DiffHunk[]
function M.parse_diff_hunks(diff)
  local hunks = {}
  for line in (diff or ''):gmatch('[^\n]+') do
    local old_start, old_len, new_start, new_len =
      line:match('^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@')
    if old_start then
      hunks[#hunks + 1] = {
        old_start = tonumber(old_start) or 0,
        old_len = tonumber(old_len == '' and '1' or old_len) or 1,
        new_start = tonumber(new_start) or 0,
        new_len = tonumber(new_len == '' and '1' or new_len) or 1,
      }
    end
  end
  return hunks
end

local marker_priority = { A = 1, C = 2, D = 3 }

---@param line integer
---@param hunks vv-utils.git.DiffHunk[]
---@return integer
local function map_index_line(line, hunks)
  local delta = 0
  for _, hunk in ipairs(hunks) do
    if hunk.old_len == 0 then
      if line > hunk.old_start then delta = delta + hunk.new_len end
    elseif line < hunk.old_start then
      break
    elseif line < hunk.old_start + hunk.old_len then
      if hunk.new_len == 0 then return math.max(hunk.new_start, 1) end
      local offset = math.min(line - hunk.old_start, hunk.new_len - 1)
      return math.max(hunk.new_start + offset, 1)
    else
      delta = delta + hunk.new_len - hunk.old_len
    end
  end
  return math.max(line + delta, 1)
end

---把以 index 为坐标的 staged markers 投影到当前 worktree buffer
---@param markers table<integer, 'A'|'C'|'D'>
---@param worktree_diff string `git diff` 输出，old=index、new=worktree
---@return table<integer, 'A'|'C'|'D'>
function M.map_index_markers(markers, worktree_diff)
  local out = {}
  local hunks = M.parse_diff_hunks(worktree_diff)
  for line, kind in pairs(markers or {}) do
    local mapped = map_index_line(line, hunks)
    local current = out[mapped]
    if not current or marker_priority[kind] > marker_priority[current] then
      out[mapped] = kind
    end
  end
  return out
end

---@class vv-utils.git.DiffLineSets
---@field staged table<integer, 'A'|'C'|'D'> HEAD 与 index 的差异，已映射到 worktree 行号 @default {}
---@field unstaged table<integer, 'A'|'C'|'D'> index 与 worktree 的差异 @default {}

---异步获取普通工作区文件的 staged / unstaged 双轨行级标记
---@param path string
---@param cb fun(sets: vv-utils.git.DiffLineSets?)
---@param opts? { root?: string }
function M.diff_line_sets(path, cb, opts)
  opts = opts or {}
  if not path or path == '' then cb(nil); return end

  local function run(root)
    if not root then cb(nil); return end

    local results = {}
    local pending = 2
    local failed = false
    local function finish(mode, result)
      if result.code ~= 0 then failed = true end
      results[mode] = result.stdout or ''
      pending = pending - 1
      if pending > 0 then return end
      if failed then cb(nil); return end

      local staged = M.parse_diff_lines(results.staged)
      cb({
        staged = M.map_index_markers(staged, results.unstaged),
        unstaged = M.parse_diff_lines(results.unstaged),
      })
    end

    local base = { 'git', '-C', root, '--no-pager', 'diff' }
    local tail = { '-U0', '--no-color', '--no-ext-diff', '--', path }
    vim.system(vim.list_extend(vim.deepcopy(base), tail), { text = true },
      vim.schedule_wrap(function(result) finish('unstaged', result) end))
    local staged_cmd = vim.list_extend(vim.deepcopy(base), { '--cached' })
    vim.list_extend(staged_cmd, tail)
    vim.system(staged_cmd, { text = true },
      vim.schedule_wrap(function(result) finish('staged', result) end))
  end

  if opts.root then run(norm(opts.root)); return end
  if vim.fn.filereadable(path) == 0 then cb(nil); return end

  path = norm(path)
  repository.root_async(vim.fs.dirname(path), run)
end

---异步获取文件的行级 git diff 标记
---@param path string
---@param cb fun(markers: table<integer, 'A'|'C'|'D'>?)
---@param opts? vv-utils.git.DiffLinesOpts
function M.diff_lines(path, cb, opts)
  opts = opts or {}
  if not path or path == '' then
    cb(nil)
    return
  end

  local mode = opts.mode or 'worktree'
  local function run(root)
    if not root then cb(nil); return end

    local cmd = { 'git', '-C', root, '--no-pager', 'diff' }
    if mode == 'staged' then cmd[#cmd + 1] = '--cached' end
    vim.list_extend(cmd, { '-U0', '--no-color', '--no-ext-diff', '--', path })

    vim.system(cmd, { text = true }, vim.schedule_wrap(function(res)
      if res.code ~= 0 then
        cb(nil)
        return
      end

      cb(M.parse_diff_lines(res.stdout or '', opts.side))
    end))
  end

  if opts.root then
    run(norm(opts.root))
    return
  end

  if vim.fn.filereadable(path) == 0 then
    cb(nil)
    return
  end

  path = norm(path)
  repository.root_async(vim.fs.dirname(path), run)
end

---@class vv-utils.git.DiffLinesOpts
---@field root? string Git 仓库根；虚拟或已删除文件必须提供 @default nil
---@field mode? 'worktree'|'staged'  比较工作树与 index，或比较 index 与 HEAD @default 'worktree'
---@field side? 'new'|'old'  将 hunk 行号投影到新侧或旧侧 @default 'new'

return M
