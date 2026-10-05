-- vv-utils.loading.win_text — 把 loading 帧写进浮窗 title / footer
--
-- 每次写入前读取槽位当前内容（含高亮 chunk）：首次写入，或当前值已不是 loading 上次写入的值（宿主改过），
-- 就把当前值记为原值。stop 时只有槽位仍是 loading 最后写入的值才恢复原值，否则保留宿主当前值；原本为空则恢复为空
-- （不在创建时读：delay_ms 期间宿主可能已改过标题，应以写入前一刻的值为准；从未写入则 stop 不动标题）
-- 宿主在 loading 期间改值：loading 继续接管显示，stop 后恢复宿主的新值
-- 同一窗口同一槽位不要叠加多个 win_text：后一个会把前一个的帧当原值，stop 后可能残留一帧 spinner；
-- 并发请求必须通过 slot() 合并成一个显示
-- 窗口关闭时自动停止。无边框或非浮窗时 set_config 失败会被吞掉，等价于不显示

local Handle = require('vv-utils.loading.handle')

local M = {}

---@param opts VVLoadingWinTextOpts 已归一化
---@param handle_opts vv-utils.loading.HandleSpec
---@return vv-utils.loading.Handle
function M.new(opts, handle_opts)
  local win, slot = opts.win, opts.slot
  -- loading 接管前槽位的内容；首次写入或宿主改过后于写入前一刻更新
  local original = nil
  -- loading 最后一次写入后读回的值（经 nvim 归一化，字符串会变成 chunk 列表），用于 stop 时判断宿主是否改过
  local written = nil

  handle_opts.render = function(frame, label)
    if not vim.api.nvim_win_is_valid(win) then return false end
    -- 比较用 nvim 归一化后的值（written 也是读回值），宿主改过或尚未写过则当前值即新的原值
    local cur = vim.api.nvim_win_get_config(win)[slot]
    if written == nil or not vim.deep_equal(cur, written) then original = cur end
    if pcall(vim.api.nvim_win_set_config, win, { [slot] = opts.format(frame, label) }) then
      written = vim.api.nvim_win_get_config(win)[slot]
    end
  end

  handle_opts.clear = function()
    if not vim.api.nvim_win_is_valid(win) then return end
    -- 从未写成功，或宿主已改成别的内容：不覆盖
    if written == nil or not vim.deep_equal(vim.api.nvim_win_get_config(win)[slot], written) then return end
    pcall(vim.api.nvim_win_set_config, win, { [slot] = original or '' })
  end

  local handle = Handle.new(handle_opts)
  if handle:is_active() and vim.api.nvim_win_is_valid(win) then
    local autocmd = vim.api.nvim_create_autocmd('WinClosed', {
      pattern = tostring(win),
      once = true,
      callback = function() handle:stop() end,
    })
    handle:on_stop(function() pcall(vim.api.nvim_del_autocmd, autocmd) end)
  end
  return handle
end

return M
