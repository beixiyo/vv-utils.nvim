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

vim.fn.delete(fixture, 'rf')

print('vv-utils fs operations: PASS')
