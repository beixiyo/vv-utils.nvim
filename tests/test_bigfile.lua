-- 大文件传统 syntax 的选择权：覆盖真实读入与 Git 风格无名快照
local H = dofile('tests/helpers.lua')
local T, child = H.new_set()

T['默认关闭传统 syntax，真实大文件与无名快照不再异步恢复高亮'] = function()
  child.lua_func(function()
    vim.cmd('filetype on')
    vim.cmd('syntax enable')
    local bigfile = require('vv-utils.bigfile')
    bigfile.setup({ notify = false, size = 128 })
    local path = vim.env.VV_TEST_TMP .. '/large.mjs'
    local lines = { '#!/usr/bin/env node' }
    for i = 1, 40 do lines[#lines + 1] = 'const value' .. i .. ' = 1;' end
    vim.fn.writefile(lines, path)
    vim.cmd.edit(vim.fn.fnameescape(path))
    local real = vim.api.nvim_get_current_buf()
    assert(vim.bo[real].filetype == 'bigfile', '实际大文件未命中保护')

    local scratch = vim.api.nvim_create_buf(false, true)
    vim.bo[scratch].buftype = 'nowrite'
    vim.api.nvim_buf_set_lines(scratch, 0, -1, false, lines)
    vim.bo[scratch].filetype = vim.filetype.match({ filename = 'revision.mjs', buf = scratch })
    assert(vim.bo[scratch].filetype == 'bigfile', '无名 Git 风格快照未命中保护')
    local settled = false
    vim.schedule(function() settled = true end)
    assert(vim.wait(500, function() return settled end, 5), 'FileType 后置处理未完成')
    assert(vim.bo[real].syntax == '', '真实大文件又恢复了昂贵的传统 syntax')
    assert(vim.bo[scratch].syntax == '', '无名快照又恢复了昂贵的传统 syntax')

    local small_path = vim.env.VV_TEST_TMP .. '/small.js'
    vim.fn.writefile({ 'const value = 1;' }, small_path)
    vim.cmd.edit(vim.fn.fnameescape(small_path))
    assert(vim.bo.filetype == 'javascript' and vim.bo.syntax == 'javascript', '大文件策略误伤普通文件高亮')
  end)
end

T['显式启用可恢复原语言 syntax，并保留自定义 setup 的原始 filetype'] = function()
  child.lua_func(function()
    vim.cmd('filetype on')
    vim.cmd('syntax enable')
    local bigfile = require('vv-utils.bigfile')
    bigfile.setup({ notify = false, size = 32, syntax = true })
    local path = vim.env.VV_TEST_TMP .. '/legacy.js'
    vim.fn.writefile({ string.rep('const value = 1; ', 10) }, path)
    vim.cmd.edit(vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()
    assert(vim.wait(500, function() return vim.bo[buf].syntax == 'javascript' end, 5), '显式启用后未恢复传统 syntax')

    local context
    bigfile.setup({ notify = false, size = 32, syntax = false, setup = function(ctx) context = ctx end })
    vim.cmd('enew')
    vim.cmd.file(vim.env.VV_TEST_TMP .. '/custom.js')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { string.rep('const value = 1; ', 10) })
    vim.bo.filetype = 'bigfile'
    assert(context and context.ft == 'javascript', '关闭 syntax 不应抹掉自定义 setup 的原语言信息')
  end)
end

return T
