-- vv-utils.match — 列表 / 侧栏过滤用的「命中判定」谓词（纯函数）
--
-- 三种模式（都大小写可选，默认不敏感）：
--   fixed   字面子串（string.find plain，不解释任何元字符）
--   subseq  子序列模糊（query 每个字符按序出现在干草堆，不要求连续；不打分）
--   regex   vim 正则（vim.regex:match_str）
--
-- 关键：compile(query) 编译一次 → 返回谓词，再对每条候选调用。
-- 避免 regex 逐条重编译（大列表下是 O(n) 次编译）。vv-explorer 的 match_regex
-- 正是「编译一次 + 循环 match_str」，这里把同一内核抽成可复用工厂。
--
-- 与打分 fuzzy（vim.fn.matchfuzzypos）的区别：这里只判「命中 / 不命中」，
-- 不打分、不重排——适合需要保持原有分组 / 顺序的列表（如 vv-flow 的编号流程）。

local M = {}

-- compile 支持的模式集；恰好也是 vv-flow 过滤模式集。
-- 注意：这不是「所有插件的」模式集——用 glob / 打分 fuzzy 的插件不走本模块。
M.MODES = { 'fixed', 'subseq', 'regex' }

-- 列表中 cur 的下一个，循环；cur 不在列表则返回首个。用于模式轮换。
---@param list any[]
---@param cur any
---@return any
function M.next_in(list, cur)
  for i, v in ipairs(list) do
    if v == cur then return list[(i % #list) + 1] end
  end
  return list[1]
end

---@param mode string
---@return string  下一个模式（fixed → subseq → regex → fixed）
function M.next_mode(mode)
  return M.next_in(M.MODES, mode)
end

-- 子序列：q 的每个字符按序出现在 hay（不要求连续）
---@param hay string
---@param q string
---@return boolean
local function subseq_match(hay, q)
  local pos = 1
  for i = 1, #q do
    local found = hay:find(q:sub(i, i), pos, true)
    if not found then return false end
    pos = found + 1
  end
  return true
end

-- 编译查询为命中判定谓词。
--   空查询 → 谓词恒 true（不过滤）
--   regex 非法 → 谓词恒 false，且第二返回值 ok=false（调用方可据此提示），不抛错
---@param query string
---@param opts? vv-utils.MatchOpts
---@return fun(hay: string): boolean predicate
---@return boolean ok  仅 regex 模式可能为 false（语法非法）；其余模式恒 true
function M.compile(query, opts)
  opts = opts or {}
  local mode = opts.mode or 'fixed'
  local ignore_case = opts.ignore_case ~= false

  if query == '' then
    return function() return true end, true
  end

  if mode == 'regex' then
    -- \c 前缀强制大小写不敏感（不依赖 'ignorecase' 选项）；用户在 query 里写 \C 可覆盖
    local pat = ignore_case and ('\\c' .. query) or query
    local ok, re = pcall(vim.regex, pat)
    if not ok or not re then
      return function() return false end, false
    end
    return function(hay)
      return re:match_str(hay) ~= nil
    end, true
  end

  local needle = ignore_case and query:lower() or query

  if mode == 'subseq' then
    return function(hay)
      return subseq_match(ignore_case and hay:lower() or hay, needle)
    end, true
  end

  -- fixed（默认）
  return function(hay)
    return (ignore_case and hay:lower() or hay):find(needle, 1, true) ~= nil
  end, true
end

return M

---@class vv-utils.MatchOpts
---@field mode? 'fixed'|'subseq'|'regex'  匹配模式 @default 'fixed'
---@field ignore_case? boolean            大小写不敏感 @default true
