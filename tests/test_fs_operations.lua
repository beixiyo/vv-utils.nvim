-- vv-utils.fs operations 真实文件系统行为测试
local this = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
local plugin_root = vim.fn.fnamemodify(this, ':h:h')

package.path = table.concat({
  plugin_root .. '/lua/?.lua',
  plugin_root .. '/lua/?/init.lua',
  package.path,
}, ';')

local Highlight = require('vv-utils.fs.file_info_highlight')
local Io = require('vv-utils.fs.io')
local Operations = require('vv-utils.fs.operations')
local Path = require('vv-utils.fs.path')
local Probe = require('vv-utils.fs.file_probe')
local Render = require('vv-utils.fs.file_render')
local fixture = vim.fn.tempname()
local upper = fixture .. '/README.MD'
local lower = fixture .. '/README.md'

vim.fn.mkdir(fixture, 'p')
vim.fn.writefile({ 'content' }, upper)

assert(Path.is_directory(fixture), 'fixture 应识别为目录')
assert(not Path.is_directory(upper), '普通文件不应识别为目录')
assert(Path.is_dir_empty(fixture) == false, '包含文件的目录不应为空')

local empty_dir = fixture .. '/empty'
vim.fn.mkdir(empty_dir)
assert(Path.is_dir_empty(empty_dir) == true, '空目录应识别为空')
local empty, empty_error = Path.is_dir_empty(upper)
assert(empty == nil and empty_error:match('not a directory'), '非目录应返回可读错误')

Operations.rename(upper, lower)

assert(vim.fn.filereadable(lower) == 1, '仅大小写重命名后应保留目标文件名')
assert(vim.fn.readfile(lower)[1] == 'content', '仅大小写重命名不应改变文件内容')

local source = fixture .. '/source.txt'
local existing = fixture .. '/existing.txt'
vim.fn.writefile({ 'source' }, source)
vim.fn.writefile({ 'existing' }, existing)

local ok, err = pcall(Operations.rename, source, existing)
assert(not ok and tostring(err):match('target exists'), '重命名仍应拒绝不同的已存在目标')
assert(vim.fn.readfile(existing)[1] == 'existing', '重命名不应覆盖不同的已存在目标')

local macho = fixture .. '/extensionless'
local macho_header = string.char(
  0xcf, 0xfa, 0xed, 0xfe,
  0x0c, 0x00, 0x00, 0x01,
  0x00, 0x00, 0x00, 0x00,
  0x02, 0x00, 0x00, 0x00
) .. string.rep('\0', 64)
Io.write_all(macho, macho_header, { mode = 493 })

local macho_info = Probe.inspect(macho)
assert(macho_info.binary, '无扩展名 Mach-O 可执行文件应按内容识别')
assert(macho_info.kind == 'Mach-O 64-bit executable', 'Mach-O 类型应由文件头识别')
assert(macho_info.architecture == 'arm64', 'Mach-O 架构应由 CPU 类型识别')
assert(macho_info.executable, '应报告可执行权限')

local private_dir = fixture .. '/private/nested'
local private_file = private_dir .. '/history.json'
Io.write_all(private_file, '{"ok":true}\n', { mode = 384, directory_mode = 448 })
assert(Io.read_all(private_file) == '{"ok":true}\n', '私有文件写入后应能读回原始内容')
assert(assert(vim.uv.fs_stat(private_file)).mode % 512 == 384, '私有文件权限应为 0600')
assert(assert(vim.uv.fs_stat(private_dir)).mode % 512 == 448, '新建父目录权限应为 0700')

local script = fixture .. '/script'
Io.write_all(script, '#!/bin/sh\necho ok\n', { mode = 493 })
assert(not Probe.is_binary(script), '无扩展名的文本可执行文件不应识别为二进制')

local allowed = fixture .. '/allowed.bin'
Io.write_all(allowed, 'binary\0content')
assert(
  not Probe.is_binary(allowed, { extensions = { bin = false } }),
  '显式 false 扩展名覆盖应跳过内容探测'
)

local forced = fixture .. '/forced.asset'
Io.write_all(forced, 'plain content')
local forced_info = Probe.inspect(forced, { extensions = { asset = true } })
assert(forced_info.binary, '显式 true 扩展名覆盖应强制识别为二进制')
assert(forced_info.kind == 'Binary data', '强制二进制元信息不应继续报告文本类型')

local info_lines = Render.lines(macho_info, { display_path = 'target/debug/vv-mcp' })
assert(info_lines[1] == 'Binary file', '二进制信息应使用共享英文标题')
assert(vim.tbl_contains(info_lines, 'Path: target/debug/vv-mcp'), '二进制信息应包含展示路径')
assert(vim.tbl_contains(info_lines, 'Type: Mach-O 64-bit executable'), '二进制信息应包含文件类型')
assert(vim.tbl_contains(info_lines, 'Architecture: arm64'), '二进制信息应包含架构')
assert(vim.tbl_contains(info_lines, 'Executable: Yes'), '二进制信息应包含可执行状态')

local info_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(info_buf, 0, -1, false, info_lines)
assert(Highlight.apply(info_buf), '二进制信息高亮应可应用到有效缓冲区')
local highlighted = {}
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(info_buf, -1, 0, -1, { details = true })) do
  highlighted[mark[4].hl_group] = true
end
assert(highlighted.VVUtilsFileInfoTitle, '应存在二进制信息标题高亮')
assert(highlighted.VVUtilsFileInfoLabel, '应存在二进制信息标签高亮')
assert(highlighted.VVUtilsFileInfoPath, '应存在二进制信息路径高亮')
assert(highlighted.VVUtilsFileInfoPositive, '应存在二进制信息正向状态高亮')
vim.api.nvim_buf_delete(info_buf, { force = true })

vim.fn.delete(fixture, 'rf')

print('vv-utils fs 操作：通过')
