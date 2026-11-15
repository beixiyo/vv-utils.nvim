-- buffer 的 Git diff 源声明：生产方与消费方之间的唯一约定
--
-- scratch buffer（diff 视图的旧侧、index 内容、冲突的 ours / theirs）没有对应的磁盘文件，
-- 状态列、滚动条这类插件无从得知该拿什么去算行级标记。生产方在这里声明「这个 buffer 的内容
-- 对应哪一次 Git 比较」，消费方读取并在声明变化时重算
--
-- 变量名与事件名只在本文件出现：生产方调 set，消费方监听 M.EVENT 并调 get，
-- 双方互不知道对方是谁
local M = {}

---声明变化时广播的 User 事件；`args.data.buf` 为对应 buffer
M.EVENT = 'VVDiffSourceChanged'

local VARIABLE = 'vv_diff_source'

---@param source any
---@return boolean
local function is_source(source)
  return type(source) == 'table' and type(source.path) == 'string' and source.path ~= ''
end

---声明或清除 buf 的 diff 源，并通知消费方
---@param buf integer
---@param source vv-utils.git.DiffSource? nil 表示清除
function M.set(buf, source)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  assert(source == nil or is_source(source), 'vv-utils.git: diff source requires a non-empty path')

  vim.b[buf][VARIABLE] = source
  vim.api.nvim_exec_autocmds('User', {
    pattern = M.EVENT,
    modeline = false,
    data = { buf = buf },
  })
end

---@param buf integer
---@return vv-utils.git.DiffSource? source 未声明或声明无效时为 nil
function M.get(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return nil end

  local source = vim.b[buf][VARIABLE]
  return is_source(source) and source or nil
end

return M
