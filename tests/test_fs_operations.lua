-- vv-utils.fs operations 真实文件系统行为测试
local this = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
local plugin_root = vim.fn.fnamemodify(this, ':h:h')

package.path = table.concat({
  plugin_root .. '/lua/?.lua',
  plugin_root .. '/lua/?/init.lua',
  package.path,
}, ';')

local Fs = require('vv-utils.fs')
local fixture = vim.fn.tempname()
local upper = fixture .. '/README.MD'
local lower = fixture .. '/README.md'

vim.fn.mkdir(fixture, 'p')
vim.fn.writefile({ 'content' }, upper)

Fs.rename(upper, lower)

assert(vim.fn.filereadable(lower) == 1, 'case-only rename should keep the file at its new spelling')
assert(vim.fn.readfile(lower)[1] == 'content', 'case-only rename should preserve file content')

local source = fixture .. '/source.txt'
local existing = fixture .. '/existing.txt'
vim.fn.writefile({ 'source' }, source)
vim.fn.writefile({ 'existing' }, existing)

local ok, err = pcall(Fs.rename, source, existing)
assert(not ok and tostring(err):match('target exists'), 'rename should still reject a different existing target')
assert(vim.fn.readfile(existing)[1] == 'existing', 'rename should never overwrite a different existing target')

local macho = fixture .. '/extensionless'
local macho_header = string.char(
  0xcf, 0xfa, 0xed, 0xfe,
  0x0c, 0x00, 0x00, 0x01,
  0x00, 0x00, 0x00, 0x00,
  0x02, 0x00, 0x00, 0x00
) .. string.rep('\0', 64)
Fs.write_all(macho, macho_header, { mode = 493 })

local macho_info = Fs.inspect_file(macho)
assert(macho_info.binary, 'extensionless Mach-O executable should be detected from content')
assert(macho_info.kind == 'Mach-O 64-bit executable', 'Mach-O kind should be derived from its header')
assert(macho_info.architecture == 'arm64', 'Mach-O architecture should be derived from its CPU type')
assert(macho_info.executable, 'executable permission should be reported')

local script = fixture .. '/script'
Fs.write_all(script, '#!/bin/sh\necho ok\n', { mode = 493 })
assert(not Fs.is_binary(script), 'extensionless text executable should not be treated as binary')

local allowed = fixture .. '/allowed.bin'
Fs.write_all(allowed, 'binary\0content')
assert(
  not Fs.is_binary(allowed, { extensions = { bin = false } }),
  'explicit false extension override should bypass content detection'
)

local forced = fixture .. '/forced.asset'
Fs.write_all(forced, 'plain content')
local forced_info = Fs.inspect_file(forced, { extensions = { asset = true } })
assert(forced_info.binary, 'explicit true extension override should force binary classification')
assert(forced_info.kind == 'Binary data', 'forced binary metadata should not report a text type')

local info_lines = Fs.file_info_lines(macho_info, { display_path = 'target/debug/vv-mcp' })
assert(info_lines[1] == 'Binary file', 'binary info should use the shared English title')
assert(vim.tbl_contains(info_lines, 'Path: target/debug/vv-mcp'), 'binary info should include display path')
assert(vim.tbl_contains(info_lines, 'Type: Mach-O 64-bit executable'), 'binary info should include type')
assert(vim.tbl_contains(info_lines, 'Architecture: arm64'), 'binary info should include architecture')
assert(vim.tbl_contains(info_lines, 'Executable: Yes'), 'binary info should include executable state')

local info_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(info_buf, 0, -1, false, info_lines)
assert(Fs.highlight_file_info(info_buf), 'binary info highlighting should apply to a valid buffer')
local highlighted = {}
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(info_buf, -1, 0, -1, { details = true })) do
  highlighted[mark[4].hl_group] = true
end
assert(highlighted.VVUtilsFileInfoTitle, 'binary info title highlight should be present')
assert(highlighted.VVUtilsFileInfoLabel, 'binary info label highlight should be present')
assert(highlighted.VVUtilsFileInfoPath, 'binary info path highlight should be present')
assert(highlighted.VVUtilsFileInfoPositive, 'binary info positive-state highlight should be present')
vim.api.nvim_buf_delete(info_buf, { force = true })

vim.fn.delete(fixture, 'rf')

print('vv-utils fs operations: PASS')
