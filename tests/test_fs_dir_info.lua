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

local DirRender = require('vv-utils.fs.dir_render')
local DirScan = require('vv-utils.fs.dir_scan')
local Highlight = require('vv-utils.fs.file_info_highlight')
local Io = require('vv-utils.fs.io')

local fixture = vim.fn.tempname()
vim.fn.mkdir(fixture .. '/nested/deep', 'p')
vim.fn.mkdir(fixture .. '/empty', 'p')

-- 3 个文件，字节数 10 + 20 + 30 = 60
Io.write_all(fixture .. '/a.txt', string.rep('a', 10))
Io.write_all(fixture .. '/nested/b.txt', string.rep('b', 20))
Io.write_all(fixture .. '/nested/deep/c.txt', string.rep('c', 30))

---@param handle VVFsDirScanHandle
---@param result table
local function wait_for(handle, result)
  vim.wait(5000, function() return result.value ~= nil or handle.is_done() end, 10)
end

-- ① 浅扫只看直接子项，不递归
local shallow = DirScan.shallow(fixture)
assert(shallow.exists and shallow.readable, 'fixture 目录应可读取')
assert(shallow.entries == 3, '浅扫只能统计直接子项，实际为 ' .. shallow.entries)
assert(shallow.dirs == 2, '浅扫应统计直接子目录，实际为 ' .. shallow.dirs)
assert(shallow.files == 1, '浅扫应统计直接文件，实际为 ' .. shallow.files)

local missing = DirScan.shallow(fixture .. '/does-not-exist')
assert(not missing.exists, '不存在的目录应报告 exists=false')
assert(not missing.readable, '不存在的目录应报告 readable=false')

-- ② 递归统计跨越嵌套层级
local recursive = {}
local recursive_handle = DirScan.scan(fixture, {
  on_done = function(result) recursive.value = result end,
})
assert(type(recursive_handle.cancel) == 'function', '扫描应返回可取消句柄')
assert(recursive.value == nil, '扫描返回句柄前不得同步调用 on_done')
wait_for(recursive_handle, recursive)

assert(recursive.value, '递归扫描应完成')
assert(recursive.value.done, '完成的扫描应报告 done=true')
assert(recursive.value.files == 3, '递归扫描应统计嵌套文件，实际为 ' .. recursive.value.files)
assert(recursive.value.dirs == 3, '递归扫描应统计嵌套目录，实际为 ' .. recursive.value.dirs)
assert(recursive.value.bytes == 60, '递归扫描应累加嵌套文件大小，实际为 ' .. recursive.value.bytes)
assert(not recursive.value.truncated, '未达到 max_entries 的扫描不应标记为截断')

-- ③ max_depth 限制递归层级
local shallowed = {}
local depth_handle = DirScan.scan(fixture, {
  max_depth = 1,
  on_done = function(result) shallowed.value = result end,
})
wait_for(depth_handle, shallowed)
assert(shallowed.value, '限制深度的扫描应完成')
assert(shallowed.value.files == 2, 'max_depth=1 应跳过更深层级，实际为 ' .. shallowed.value.files)
assert(shallowed.value.bytes == 30, 'max_depth=1 只能累加可达文件，实际为 ' .. shallowed.value.bytes)

-- ④ max_entries 截断如实标记
local truncated = {}
local truncated_handle = DirScan.scan(fixture, {
  max_entries = 2,
  on_done = function(result) truncated.value = result end,
})
wait_for(truncated_handle, truncated)
assert(truncated.value, '截断扫描仍应完成')
assert(truncated.value.truncated, '达到 max_entries 应设置 truncated=true')
assert(truncated.value.entries == 2, '截断扫描应在 entry 上限停止，实际为 ' .. truncated.value.entries)

-- ⑤ cancel 之后不再回写
local cancelled = { calls = 0 }
local cancelled_handle = DirScan.scan(fixture, {
  budget_entries = 1,
  on_progress = function() cancelled.calls = cancelled.calls + 1 end,
  on_done = function() cancelled.calls = cancelled.calls + 1 end,
})
cancelled_handle.cancel()
cancelled_handle.cancel()
vim.wait(200, function() return false end, 10)
assert(cancelled.calls == 0, '取消后的扫描不得报告进度或完成')
assert(not cancelled_handle.is_done(), '取消后的扫描不应报告 done')

-- ⑥ symlink 不跟随，指向祖先目录也不成环
do
  local linked, link_error = vim.uv.fs_symlink(fixture, fixture .. '/nested/loop')
  assert(linked, '无法创建 symlink fixture，不能静默跳过环路覆盖：' .. tostring(link_error))
  local looped = {}
  local loop_handle = DirScan.scan(fixture, {
    max_entries = 10000,
    on_done = function(result) looped.value = result end,
  })
  wait_for(loop_handle, looped)
  assert(looped.value, '指向祖先的 symlink 也不应阻止扫描结束')
  assert(not looped.value.truncated, 'symlink 环路不应导致扫描被截断')
  assert(looped.value.links == 1, 'symlink 应计为链接，实际为 ' .. looped.value.links)
  assert(looped.value.files == 3, 'symlink 目标内容不得重复统计')
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
  Io.write_all(('%s/f%04d.txt'):format(wide, index), 'x')
end

local iterations = 0
local idle = assert(vim.uv.new_idle())
idle:start(function() iterations = iterations + 1 end)

local sliced = {}
local sliced_handle = DirScan.scan(wide, {
  budget_entries = 5,
  on_done = function(result) sliced.value = result end,
})
wait_for(sliced_handle, sliced)
idle:stop()
idle:close()

assert(sliced.value and sliced.value.files == 600,
  '分片扫描仍应统计全部文件，实际为 ' .. tostring(sliced.value and sliced.value.files))
-- 600 个 entry / 每片 5 个 = 120 片；每片之间都让出的话迭代次数远高于这个下界
assert(iterations >= 50,
  '分片扫描必须在片段之间让出事件循环，但当前只迭代了 '
  .. iterations .. ' times')

vim.fn.delete(wide, 'rf')

-- ⑧ 渲染：扫描中与截断状态必须与完成状态在文本上可分
local pending_lines = DirRender.lines(shallow, {
  display_path = 'project',
  scan = { files = 1, dirs = 0, links = 0, bytes = 10, entries = 1, truncated = false, done = false },
})
assert(pending_lines[1] == 'Directory', '目录信息应使用共享英文标题')
assert(vim.tbl_contains(pending_lines, 'Path: project'), '目录信息应包含展示路径')
assert(vim.tbl_contains(pending_lines, 'Items: 3 (2 dirs, 1 files)'), '目录信息应包含浅扫统计')
assert(
  vim.tbl_contains(pending_lines, 'Total files: ≥ 1 (scanning…)'),
  '未完成扫描必须标记其中间数值'
)

local done_lines = DirRender.lines(shallow, {
  scan = { files = 3, dirs = 3, links = 0, bytes = 60, entries = 6, truncated = false, done = true },
})
assert(vim.tbl_contains(done_lines, 'Total files: 3'), '完成的扫描应报告普通数值')
assert(vim.tbl_contains(done_lines, 'Total size: 60 B (60 bytes)'), '完成的扫描应报告精确字节数')

local truncated_lines = DirRender.lines(shallow, {
  scan = { files = 2000, dirs = 0, links = 0, bytes = 1024, entries = 2000, truncated = true, done = true },
})
assert(
  vim.tbl_contains(truncated_lines, 'Total files: ≥ 2,000 (truncated at 2,000 entries)'),
  '截断扫描必须明确说明，而不能把部分统计伪装成最终结果'
)

-- ⑨ 高亮：扫描中与截断分别落到独立分组，不与正常值同色
local info_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(info_buf, 0, -1, false, pending_lines)
assert(Highlight.apply(info_buf), '目录信息高亮应可应用到有效缓冲区')
local highlighted = {}
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(info_buf, -1, 0, -1, { details = true })) do
  highlighted[mark[4].hl_group] = true
end
assert(highlighted.VVUtilsFileInfoPending, '扫描中的数值应使用 pending 高亮组')

vim.api.nvim_buf_set_lines(info_buf, 0, -1, false, truncated_lines)
Highlight.apply(info_buf)
local truncated_hl = {}
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(info_buf, -1, 0, -1, { details = true })) do
  truncated_hl[mark[4].hl_group] = true
end
assert(truncated_hl.VVUtilsFileInfoTruncated, '截断数值应使用 truncated 高亮组')
vim.api.nvim_buf_delete(info_buf, { force = true })

vim.fn.delete(fixture, 'rf')

print('vv-utils fs 目录信息：通过')
