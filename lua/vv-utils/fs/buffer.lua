-- 文件移动后同步已加载 Neovim buffer 的路径
--
-- 机制、副作用与限制以 README“sync_buffers 边界”为准，这里只留不可破坏的不变量：
--   - 绝不重读已修改的 buffer：数据安全靠“从不碰未保存内容”从构造上保证，而不是靠事后恢复
--   - 只有 buftype 为空、未修改、目标是可读普通文件的 buffer 才会重读；其余只改名（目标已存在时 `:w` 多半仍会 E13，具体见 README）

local M = {}

local function norm(path) return vim.fs.normalize(path) end

local function lines_of(buf) return vim.api.nvim_buf_get_lines(buf, 0, -1, false) end

local function usable(buf) return vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) end

-- 目标必须是可读的普通文件。不用 filereadable：它对 FIFO 也返回 1，而 `:edit!` 读命名管道会永久阻塞 nvim；
-- fs_stat 跟随软链接，目录、设备、socket、不存在都过滤掉
local function rereadable(target)
  local stat = vim.uv.fs_stat(target)
  return stat ~= nil and stat.type == 'file' and vim.uv.fs_access(target, 'R') == true
end

-- 在重读开始时的窗口里执行 fn（rundo / winrestview 作用于当前窗口与 buffer，autocmd 切走窗口后不能落到别处）
-- 该窗口已关闭或不再显示 buf 时退化为只绑定 buffer；view 类操作传 view_only=true，此时直接跳过
local function in_target(snap, fn, view_only)
  local win = snap.win
  if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == snap.buf then
    return pcall(vim.api.nvim_win_call, win, fn)
  end
  if view_only then return false end
  return pcall(vim.api.nvim_buf_call, snap.buf, fn)
end

-- 重读前的状态（必须在 nvim_buf_call 内、重读之前采集）：
--   lines     仅在重读出错、内容被破坏时用来恢复
--   opts      fileformat/fileencoding/endofline/fixendofline/bomb，同样只服务出错恢复
--   readonly  重读按文件权限重置它，所以保存后恢复
--   view/win  光标与滚动位置，以及重读开始时的当前窗口（恢复时显式绑定它）
--   undo_file wundo! 出的临时 undo 文件；没有 undo 历史或写失败时为 nil
--   clients   重读前附着的 LSP client id
---@param buf integer
local function snapshot(buf)
  local bo = vim.bo[buf]
  local snap = {
    buf = buf,
    win = vim.api.nvim_get_current_win(),
    lines = lines_of(buf),
    opts = {
      fileformat = bo.fileformat,
      fileencoding = bo.fileencoding,
      endofline = bo.endofline,
      fixendofline = bo.fixendofline,
      bomb = bo.bomb,
    },
    readonly = bo.readonly,
    view = vim.fn.winsaveview(),
    clients = vim.tbl_map(function(c) return c.id end, vim.lsp.get_clients({ bufnr = buf })),
  }

  -- 保存过的 buffer 有 undo 历史很常见：行数 ≥ undoreload 时 `:edit!` 会清空它，所以先落到临时文件，用完即删
  if vim.fn.undotree().seq_last > 0 then
    local tmp = vim.fn.tempname()
    if pcall(vim.cmd, 'silent wundo! ' .. vim.fn.fnameescape(tmp)) and vim.uv.fs_stat(tmp) then
      snap.undo_file = tmp
    end
  end
  return snap
end

-- 重读显式带 ++enc/++ff，避免重新探测编码与换行
local function reread(snap)
  local cmd = 'keepalt keepjumps silent edit!'
  if snap.opts.fileencoding ~= '' then cmd = cmd .. ' ++enc=' .. snap.opts.fileencoding end
  if snap.opts.fileformat ~= '' then cmd = cmd .. ' ++ff=' .. snap.opts.fileformat end
  return pcall(vim.cmd, cmd)
end

-- `:edit!` 会让 buffer 的所有 client detach。FileType 驱动的会在重读时重新附着；
-- `vim.lsp.start` 手动附着的不会。这里只补救「仍在运行但没重新附着」的 client，已附着的不重复附着
local function reattach_clients(snap)
  for _, id in ipairs(snap.clients) do
    local client = vim.lsp.get_client_by_id(id)
    if client and not client:is_stopped() and #vim.lsp.get_clients({ bufnr = snap.buf, id = id }) == 0 then
      pcall(vim.lsp.buf_attach_client, snap.buf, id)
    end
  end
end

-- 重读后把 buffer 还原到快照状态。是否恢复内容只取决于「重读是否出错」，不依赖 :edit! 的返回值：
-- autocmd 报错时磁盘内容其实已经读进来了，但 BufReadPre 报错会把 buffer 清空并误置 readonly
---@return boolean restored buffer 内容已与快照一致
local function restore(snap, ok)
  local buf = snap.buf
  if not usable(buf) then return false end

  local bo = vim.bo[buf]
  local restored = true

  if not ok then
    -- 写回前先清掉（可能被误置的）readonly，否则对 readonly buffer 写入会弹 W10；真正的值在最后补回
    pcall(function() bo.readonly = false end)
    if not vim.deep_equal(lines_of(buf), snap.lines) then
      pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, snap.lines)
    end
    restored = vim.deep_equal(lines_of(buf), snap.lines)
    if restored then
      for k, v in pairs(snap.opts) do pcall(function() bo[k] = v end) end
    end
  end

  -- rundo 要求当前内容与保存时一致，所以只在内容确认无误后做；不一致时报错被吞，退化为没有 undo 历史
  if snap.undo_file and restored then
    in_target(snap, function() vim.cmd('silent rundo ' .. vim.fn.fnameescape(snap.undo_file)) end)
  end

  -- 重读按文件权限重置 readonly，用户手动 :set ro 的要补回。放在写回与 rundo 之后，
  -- 此时不会再触发 W10
  if snap.readonly then pcall(function() bo.readonly = true end) end

  -- 恢复行会把 modified 置 true，而进入这里的 buffer 重读前一定是未修改的
  if not ok and restored then pcall(function() bo.modified = false end) end

  in_target(snap, function() vim.fn.winrestview(snap.view) end, true)
  reattach_clients(snap)
  return restored
end

-- 重读期间用户 autocmd（BufReadPost/FileType 里的 wincmd、close、bwipeout 等）可能把「当前 buffer」
-- 切到另一个已修改的 buffer；`:edit!` 读完后会把当前 buffer 标成未修改，于是那个无关 buffer 的 modified
-- 被误清，之后 :qa 不再提醒、autoread 还可能用磁盘内容覆盖它。重读前记下它们，重读后按需补回
---@param target_buf integer
---@return integer[]
local function modified_others(target_buf)
  local result = {}
  for _, other in ipairs(vim.api.nvim_list_bufs()) do
    if other ~= target_buf and usable(other) and vim.bo[other].modified then result[#result + 1] = other end
  end
  return result
end

---@param others integer[]
local function keep_modified(others)
  for _, other in ipairs(others) do
    if usable(other) and not vim.bo[other].modified then pcall(function() vim.bo[other].modified = true end) end
  end
end

-- 清除改名 buffer 的 notedited 标记。入口与每次使用 bufnr 前都要校验有效：
-- BufFilePost 等 autocmd 可能已经把 buffer wipe 掉
---@param buf integer
---@param target string
---@param was_modified boolean 改名前的 modified 状态；BufFilePost 之类的 autocmd 可能已把它清掉，以改名前为准
local function clear_notedited(buf, target, was_modified)
  if not usable(buf) then return end

  local bo = vim.bo[buf]
  if bo.buftype ~= '' or bo.modified or was_modified then return end
  if not rereadable(target) then return end

  pcall(vim.api.nvim_buf_call, buf, function()
    local snap = snapshot(buf)
    local others = modified_others(buf)
    local ok, err = reread(snap)
    local done, restored = pcall(restore, snap, ok)
    restored = done and restored
    keep_modified(others)

    if not ok then
      vim.notify(
        ('vv-utils.fs: 重读 %s 时报错（多半来自 BufReadPre/BufReadPost/FileType 等 autocmd）：%s\n%s'):format(
          target,
          tostring(err),
          restored and 'buffer 内容与状态已按重读前保存的恢复' or 'buffer 内容未能完整恢复，请检查'
        ),
        vim.log.levels.WARN
      )
    end

    if snap.undo_file then vim.fn.delete(snap.undo_file) end
  end)
end

--- 文件移动后把已加载 buffer 同步到新路径（`old` 可为文件或目录）
---
--- 命中的 buffer 会 `nvim_buf_set_name` 并触发 `BufFilePost`；其中未修改的普通文件 buffer 还会重读以清除 notedited
--- 已修改 buffer 只改名、不重读，对已存在的目标 `:w` 仍报 E13，调用方需自行 `write!`
--- 重读的副作用、跳过条件与限制见 README“sync_buffers 边界”。未命中的 buffer 不受影响，也不会向调用方抛错
---@param old string
---@param new string
function M.sync_buffers(old, new)
  old = norm(old)
  new = norm(new)

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    -- 前面 buffer 的 autocmd 可能 wipe 了后面的 buffer，每轮都重新校验
    if usable(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name == '' then goto continue end

      local normalized = norm(name)
      local target

      if normalized == old then
        target = new
      elseif normalized:sub(1, #old + 1) == old .. '/' then
        target = new .. normalized:sub(#old + 1)
      end

      local was_modified = target ~= nil and vim.bo[buf].modified
      if target and pcall(vim.api.nvim_buf_set_name, buf, target) then
        pcall(vim.api.nvim_buf_call, buf, function()
          vim.cmd('silent! doautocmd BufFilePost')
        end)
        clear_notedited(buf, target, was_modified)
      end

      ::continue::
    end
  end
end

return M
