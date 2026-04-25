-- 删除 buffer 不破坏窗口布局
--
-- 关键点：直接 `:bdelete` 会把包含它的窗口也关掉；这里先把窗口里的 buf 换成
-- "最近使用的其它 listed buffer"（没有则新建空 buf），然后再 bdelete 原 buf
--
-- API:
--   M(buf?)    / M.delete(buf?|opts?)  — 删当前或指定 buf
--   M.all()                            — 删所有 listed buffer
--   M.other()                          — 删除当前以外的所有 listed buffer
--   M.smart()                          — 智能关闭：浮窗→关浮窗；有分屏→关分屏；否则 delete()
--   M.is_throwaway(buf)                — 判定空 [No Name]（无 buftype/无名/未改/空内容）
--   M.wipe_if_throwaway(buf)           — 上述判定为真且不在任何窗时 wipe，用于"主窗 buf 被替换"
--                                        场景清理 startup [No Name] / dashboard 残留

local M = setmetatable({}, {
  __call = function(t, arg) return t.delete(arg) end,
})

---@param buf integer
local function replace_in_windows(buf)
  local info = vim.fn.getbufinfo({ buflisted = 1 })
  info = vim.tbl_filter(function(b) return b.bufnr ~= buf end, info)
  table.sort(info, function(a, b) return a.lastused > b.lastused end)
  local new_buf = info[1] and info[1].bufnr or vim.api.nvim_create_buf(true, false)

  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local target = new_buf
    vim.api.nvim_win_call(win, function()
      local alt = vim.fn.bufnr("#")
      if alt > 0 and alt ~= buf and vim.bo[alt].buflisted then target = alt end
    end)
    vim.api.nvim_win_set_buf(win, target)
  end
end

---@param arg? integer|{buf?:integer, force?:boolean, filter?:fun(b:integer):boolean}
function M.delete(arg)
  local opts = type(arg) == "number" and { buf = arg } or (arg or {})

  if type(opts.filter) == "function" then
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[b].buflisted and opts.filter(b) then
        M.delete({ buf = b, force = opts.force })
      end
    end
    return
  end

  local buf = opts.buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then return end

  -- modified 且非强制：弹确认
  if vim.bo[buf].modified and not opts.force then
    local ok, choice = pcall(vim.fn.confirm,
      ("Save changes to %q?"):format(vim.fn.bufname(buf)), "&Yes\n&No\n&Cancel")
    if not ok or choice == 0 or choice == 3 then return end
    if choice == 1 then vim.api.nvim_buf_call(buf, vim.cmd.write) end
  end

  replace_in_windows(buf)
  if vim.api.nvim_buf_is_valid(buf) then pcall(vim.cmd, "bdelete! " .. buf) end
end

function M.all()
  M.delete({ filter = function() return true end })
end

function M.other()
  local cur = vim.api.nvim_get_current_buf()
  M.delete({ filter = function(b) return b ~= cur end })
end

--- 判定 buf 是否为"可丢弃的空 [No Name]"
--- 条件：buftype 为空（普通文件 buf）+ 无名 + 未修改 + 内容为空（0 行或单空行）
--- 满足时 wipe 不会丢任何用户数据
---@param buf integer
---@return boolean
function M.is_throwaway(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return false end
  if vim.bo[buf].buftype ~= "" then return false end
  if vim.api.nvim_buf_get_name(buf) ~= "" then return false end
  if vim.bo[buf].modified then return false end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, 2, false)
  if #lines > 1 then return false end
  if lines[1] and lines[1] ~= "" then return false end
  return true
end

--- 若 buf 是 throwaway 且不在任何窗口可见 → wipe
--- 用于"主窗 buf 被另一个 buf 替换"之后清理 startup [No Name] / dashboard 残留
---@param buf integer
---@return boolean wiped
function M.wipe_if_throwaway(buf)
  if not M.is_throwaway(buf) then return false end
  if #vim.fn.win_findbuf(buf) > 0 then return false end
  return pcall(vim.api.nvim_buf_delete, buf, { force = false })
end

-- 智能关闭优先级：焦点浮窗 → 关浮窗；当前 tab 有多个普通窗口 → close 当前分屏；否则 delete()
function M.smart()
  local cur = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_config(cur).relative ~= "" then
    vim.api.nvim_win_close(cur, false)
    return
  end
  local normal = vim.tbl_filter(function(w)
    return vim.api.nvim_win_get_config(w).relative == ""
  end, vim.api.nvim_tabpage_list_wins(0))
  if #normal > 1 then
    vim.cmd("close")
  else
    M.delete()
  end
end

return M
