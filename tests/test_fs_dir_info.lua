-- vv-utils.fs 目录统计的真实文件系统行为测试
--
-- 覆盖递归扫描必须守住的三条契约：
--   ① 统计口径正确（嵌套目录的字节数与文件数）
--   ② max_entries 截断后如实标记，而不是把中间值当成结果
--   ③ cancel 之后不再回写（异步结果不能落到已被取消的调用方身上）
--   ④ symlink 不被跟随，指向祖先目录也不会成环
local this = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
local plugin_root = vim.fn.fnamemodify(this, ':h:h')

package.path = table.concat({
  plugin_root .. '/lua/?.lua',
  plugin_root .. '/lua/?/init.lua',
  package.path,
}, ';')

local Fs = require('vv-utils.fs')

local fixture = vim.fn.tempname()
vim.fn.mkdir(fixture .. '/nested/deep', 'p')
vim.fn.mkdir(fixture .. '/empty', 'p')

-- 3 个文件，字节数 10 + 20 + 30 = 60
Fs.write_all(fixture .. '/a.txt', string.rep('a', 10))
Fs.write_all(fixture .. '/nested/b.txt', string.rep('b', 20))
Fs.write_all(fixture .. '/nested/deep/c.txt', string.rep('c', 30))

---@param handle VVFsDirScanHandle
---@param result table
local function wait_for(handle, result)
  vim.wait(5000, function() return result.value ~= nil or handle.is_done() end, 10)
end

-- ① 浅扫只看直接子项，不递归
local shallow = Fs.inspect_dir(fixture)
assert(shallow.exists and shallow.readable, 'fixture directory should be readable')
assert(shallow.entries == 3, 'shallow scan should only count direct children, got ' .. shallow.entries)
assert(shallow.dirs == 2, 'shallow scan should count direct subdirectories, got ' .. shallow.dirs)
assert(shallow.files == 1, 'shallow scan should count direct files, got ' .. shallow.files)

local missing = Fs.inspect_dir(fixture .. '/does-not-exist')
assert(not missing.exists, 'missing directory should report exists=false')
assert(not missing.readable, 'missing directory should report readable=false')

-- ② 递归统计跨越嵌套层级
local recursive = {}
local recursive_handle = Fs.scan_dir(fixture, {
  on_done = function(result) recursive.value = result end,
})
assert(type(recursive_handle.cancel) == 'function', 'scan should return a cancellable handle')
assert(recursive.value == nil, 'scan must not invoke on_done synchronously before returning its handle')
wait_for(recursive_handle, recursive)

assert(recursive.value, 'recursive scan should complete')
assert(recursive.value.done, 'completed scan should report done=true')
assert(recursive.value.files == 3, 'recursive scan should count nested files, got ' .. recursive.value.files)
assert(recursive.value.dirs == 3, 'recursive scan should count nested dirs, got ' .. recursive.value.dirs)
assert(recursive.value.bytes == 60, 'recursive scan should sum nested file sizes, got ' .. recursive.value.bytes)
assert(not recursive.value.truncated, 'a scan below max_entries should not be marked truncated')

-- ③ max_depth 限制递归层级
local shallowed = {}
local depth_handle = Fs.scan_dir(fixture, {
  max_depth = 1,
  on_done = function(result) shallowed.value = result end,
})
wait_for(depth_handle, shallowed)
assert(shallowed.value, 'depth-limited scan should complete')
assert(shallowed.value.files == 2, 'max_depth=1 should skip the deep level, got ' .. shallowed.value.files)
assert(shallowed.value.bytes == 30, 'max_depth=1 should only sum reachable files, got ' .. shallowed.value.bytes)

-- ④ max_entries 截断如实标记
local truncated = {}
local truncated_handle = Fs.scan_dir(fixture, {
  max_entries = 2,
  on_done = function(result) truncated.value = result end,
})
wait_for(truncated_handle, truncated)
assert(truncated.value, 'truncated scan should still finish')
assert(truncated.value.truncated, 'hitting max_entries should set truncated=true')
assert(truncated.value.entries == 2, 'truncated scan should stop at the entry cap, got ' .. truncated.value.entries)

-- ⑤ cancel 之后不再回写
local cancelled = { calls = 0 }
local cancelled_handle = Fs.scan_dir(fixture, {
  budget_entries = 1,
  on_progress = function() cancelled.calls = cancelled.calls + 1 end,
  on_done = function() cancelled.calls = cancelled.calls + 1 end,
})
cancelled_handle.cancel()
cancelled_handle.cancel()
vim.wait(200, function() return false end, 10)
assert(cancelled.calls == 0, 'a cancelled scan must not report progress or completion')
assert(not cancelled_handle.is_done(), 'a cancelled scan should never be reported as done')

-- ⑥ symlink 不跟随，指向祖先目录也不成环
do
  local linked, link_error = vim.uv.fs_symlink(fixture, fixture .. '/nested/loop')
  assert(linked, '无法创建 symlink fixture，不能静默跳过环路覆盖: ' .. tostring(link_error))
  local looped = {}
  local loop_handle = Fs.scan_dir(fixture, {
    max_entries = 10000,
    on_done = function(result) looped.value = result end,
  })
  wait_for(loop_handle, looped)
  assert(looped.value, 'scan should terminate even with a symlink pointing at an ancestor')
  assert(not looped.value.truncated, 'a symlink loop should not inflate the scan into truncation')
  assert(looped.value.links == 1, 'symlink should be counted as a link, got ' .. looped.value.links)
  assert(looped.value.files == 3, 'symlink target contents must not be counted twice')
  vim.fn.delete(fixture .. '/nested/loop')
end

-- ⑦ 分片必须真的让出事件循环
--
-- `vim.schedule` 自递归会在同一批次里被排空，分片退化成忙循环：单片耗时看着仍然
-- 很小，但主线程从头到尾没有还给编辑器。uv idle 每轮事件循环迭代触发一次，忙循环
-- 下会被饿死，因此它的计数直接反映「分片之间到底有没有让出」
local wide = vim.fn.tempname()
vim.fn.mkdir(wide, 'p')
for index = 1, 600 do
  Fs.write_all(('%s/f%04d.txt'):format(wide, index), 'x')
end

local iterations = 0
local idle = assert(vim.uv.new_idle())
idle:start(function() iterations = iterations + 1 end)

local sliced = {}
local sliced_handle = Fs.scan_dir(wide, {
  budget_entries = 5,
  on_done = function(result) sliced.value = result end,
})
wait_for(sliced_handle, sliced)
idle:stop()
idle:close()

assert(sliced.value and sliced.value.files == 600,
  'sliced scan should still count every file, got ' .. tostring(sliced.value and sliced.value.files))
-- 600 个 entry / 每片 5 个 = 120 片；每片之间都让出的话迭代次数远高于这个下界
assert(iterations >= 50,
  'a sliced scan must yield the event loop between slices, but the loop only iterated '
  .. iterations .. ' times')

vim.fn.delete(wide, 'rf')

-- ⑧ 渲染：扫描中与截断状态必须与完成状态在文本上可分
local pending_lines = Fs.dir_info_lines(shallow, {
  display_path = 'project',
  scan = { files = 1, dirs = 0, links = 0, bytes = 10, entries = 1, truncated = false, done = false },
})
assert(pending_lines[1] == 'Directory', 'dir info should use the shared English title')
assert(vim.tbl_contains(pending_lines, 'Path: project'), 'dir info should include display path')
assert(vim.tbl_contains(pending_lines, 'Items: 3 (2 dirs, 1 files)'), 'dir info should include shallow counts')
assert(
  vim.tbl_contains(pending_lines, 'Total files: ≥ 1 (scanning…)'),
  'an unfinished scan must mark its numbers as intermediate'
)

local done_lines = Fs.dir_info_lines(shallow, {
  scan = { files = 3, dirs = 3, links = 0, bytes = 60, entries = 6, truncated = false, done = true },
})
assert(vim.tbl_contains(done_lines, 'Total files: 3'), 'a finished scan should report plain numbers')
assert(vim.tbl_contains(done_lines, 'Total size: 60 B (60 bytes)'), 'a finished scan should report exact bytes')

local truncated_lines = Fs.dir_info_lines(shallow, {
  scan = { files = 2000, dirs = 0, links = 0, bytes = 1024, entries = 2000, truncated = true, done = true },
})
assert(
  vim.tbl_contains(truncated_lines, 'Total files: ≥ 2,000 (truncated at 2,000 entries)'),
  'a truncated scan must say so instead of presenting a partial count as the result'
)

-- ⑨ 高亮：扫描中与截断分别落到独立分组，不与正常值同色
local info_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(info_buf, 0, -1, false, pending_lines)
assert(Fs.highlight_file_info(info_buf), 'dir info highlighting should apply to a valid buffer')
local highlighted = {}
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(info_buf, -1, 0, -1, { details = true })) do
  highlighted[mark[4].hl_group] = true
end
assert(highlighted.VVUtilsFileInfoPending, 'scanning values should use the pending highlight group')

vim.api.nvim_buf_set_lines(info_buf, 0, -1, false, truncated_lines)
Fs.highlight_file_info(info_buf)
local truncated_hl = {}
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(info_buf, -1, 0, -1, { details = true })) do
  truncated_hl[mark[4].hl_group] = true
end
assert(truncated_hl.VVUtilsFileInfoTruncated, 'truncated values should use the truncated highlight group')
vim.api.nvim_buf_delete(info_buf, { force = true })

vim.fn.delete(fixture, 'rf')

print('vv-utils fs dir info: PASS')
