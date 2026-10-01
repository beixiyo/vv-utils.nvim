-- vv-utils.fs.sync_buffers 的“出错与旁路”场景（只涉及未修改 buffer，已修改 buffer 从不被重读）：
-- 重读被用户 autocmd 搞砸、autocmd 切走窗口、手动附着的 LSP、无法恢复时的提示
local this = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
local plugin_root = vim.fn.fnamemodify(this, ':h:h')

package.path = table.concat({
  plugin_root .. '/lua/?.lua',
  plugin_root .. '/lua/?/init.lua',
  package.path,
}, ';')

vim.cmd('filetype plugin on')

local Fs = require('vv-utils.fs')

-- macOS 的 tempname 位于 /var（指向 /private/var 的符号链接），先 mkdir 再规范化
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
root = assert(vim.uv.fs_realpath(root))

local function open(path, lines)
  vim.fn.writefile(lines, path)
  vim.cmd('silent edit ' .. vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

local function lines_of(buf) return vim.api.nvim_buf_get_lines(buf, 0, -1, false) end

local function in_buf(buf, fn) return vim.api.nvim_buf_call(buf, fn) end

local function write(buf, bang)
  return pcall(in_buf, buf, function() vim.cmd(bang and 'silent write!' or 'silent write') end)
end

local function make_lines(count)
  local out = {}
  for i = 1, count do out[i] = 'l' .. i end
  return out
end

--- 捕获 fn 期间的 vim.notify，返回通知列表
local function capture_notify(fn)
  local notes = {}
  local orig = vim.notify
  vim.notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
  local ok, err = pcall(fn)
  vim.notify = orig
  assert(ok, err)
  return notes
end

local function find_note(notes, level, pattern)
  for _, note in ipairs(notes) do
    if note.level == level and note.msg:find(pattern, 1, true) then return note end
  end
end

local n = 0
local function next_paths(ext)
  n = n + 1
  return ('%s/r%d.%s'):format(root, n, ext or 'lua'), ('%s/r%dx.%s'):format(root, n, ext or 'lua')
end

-- 1. 重读时 BufReadPre / BufReadPost / FileType 里的 autocmd 报错：
--    `:edit!` 其实已把磁盘内容读进来，只是 vim.cmd 最后抛错，BufReadPre 报错还会把 buffer 清空成一个空行并置 readonly
--    内容、modified、readonly 与 undo 都必须还原，并且必须有 WARN 把错误告诉用户；
--    notedited 没清掉，:w 仍报 E13，:w! 写出的必须是用户内容
local failures = {
  { name = 'error()', trigger = function() error('boom-from-autocmd') end, marker = 'boom-from-autocmd' },
  { name = 'E117', trigger = function() vim.cmd('call NoSuchFunction()') end, marker = 'E117' },
}

for _, event in ipairs({ 'BufReadPre', 'BufReadPost', 'FileType' }) do
  for _, failure in ipairs(failures) do
    for _, count in ipairs({ 5, 10050 }) do -- 10050 > 'undoreload'，`:edit!` 本身会清掉 undo
      for _, ro in ipairs({ false, true }) do
        local label = ('%s + %s, %d 行, %s'):format(event, failure.name, count, ro and '手动 ro' or '可写')
        local old, new = next_paths()
        local buf = open(old, make_lines(count))
        -- 已保存且有 undo 历史（最常见的未修改 buffer）：BufReadPre 报错清空 buffer 后恢复行会把 modified 置 true，
        -- 之后必须改回 false；rundo 不会替我们改
        for _, text in ipairs({ 'A', 'B' }) do
          vim.api.nvim_buf_set_lines(buf, 0, 1, false, { text })
          vim.cmd('let &undolevels = &undolevels') -- 每次编辑一个独立的 undo 步
        end
        assert(write(buf) and not vim.bo[buf].modified)
        local want = lines_of(buf)
        if ro then vim.bo[buf].readonly = true end

        local group = vim.api.nvim_create_augroup('test_sync_buffers_fail', { clear = true })
        vim.api.nvim_create_autocmd(event, {
          group = group,
          pattern = event == 'FileType' and 'lua' or '*',
          callback = function(args)
            -- 只在改名后的重读里报错，打开原文件时不报
            if vim.api.nvim_buf_get_name(args.buf) == new then failure.trigger() end
          end,
        })

        assert(vim.uv.fs_rename(old, new))
        local notes = capture_notify(function() Fs.sync_buffers(old, new) end)
        vim.api.nvim_del_augroup_by_id(group)

        assert(vim.deep_equal(lines_of(buf), want), label .. '：用户内容应保留，实际前两行 ' .. vim.inspect(vim.list_slice(lines_of(buf), 1, 2)))
        assert(not vim.bo[buf].modified, label .. '：modified 应为 false')
        assert(vim.bo[buf].readonly == ro, label .. '：readonly 应为 ' .. tostring(ro) .. '，实际 ' .. tostring(vim.bo[buf].readonly))
        assert(vim.bo[buf].modifiable, label .. '：modifiable 应保持')
        local warn = find_note(notes, vim.log.levels.WARN, failure.marker)
        assert(warn, label .. '：应有 WARN 通知带出 autocmd 的错误信息，实际 ' .. vim.inspect(notes))
        assert(warn.msg:find('已按重读前保存的恢复', 1, true), label .. '：WARN 应说明内容已恢复: ' .. warn.msg)
        assert(not find_note(notes, vim.log.levels.ERROR, ''), label .. '：不应有 ERROR 通知')

        -- undo 链完整：保存点之前两步，撤销回到磁盘原始内容，redo 回到保存点且 unmodified
        in_buf(buf, function() vim.cmd('silent undo') end)
        assert(lines_of(buf)[1] == 'A', label .. '：第 1 次 undo 应回到 A，实际 ' .. lines_of(buf)[1])
        in_buf(buf, function() vim.cmd('silent undo') end)
        assert(lines_of(buf)[1] == 'l1' and vim.bo[buf].modified, label .. '：第 2 次 undo 应回到最初内容，实际 ' .. lines_of(buf)[1])
        in_buf(buf, function() vim.cmd('silent redo | silent redo') end)
        assert(lines_of(buf)[1] == 'B' and not vim.bo[buf].modified, label .. '：redo 应回到保存点 unmodified')

        -- 重读被中断，notedited 没清掉：:w 仍报 E13，:w! 写出的是用户内容
        -- （readonly 的 E45 会先于 E13 报出，所以先清掉 ro 再试）
        if ro then vim.bo[buf].readonly = false end
        local ok, err = write(buf)
        assert(not ok and tostring(err):find('E13', 1, true), label .. '：重读报错后 :w 应仍报 E13，实际 ' .. tostring(err))
        assert(write(buf, true), label .. '：:w! 应成功')
        assert(vim.deep_equal(vim.fn.readfile(new), want), label .. '：:w! 写入的应是用户内容')
      end
    end
  end
end

-- 2. 无法恢复时的措辞：重读出错且内容与快照不同（磁盘被别人改过）又被 autocmd 置为 nomodifiable，恢复写不进去，
--    WARN 必须如实说“未能完整恢复”，而不是谎称已恢复
do
  local old, new = next_paths('txt')
  local buf = open(old, { 'orig' })
  assert(vim.uv.fs_rename(old, new))
  vim.fn.writefile({ 'changed-on-disk' }, new)
  local group = vim.api.nvim_create_augroup('test_sync_buffers_unrestorable', { clear = true })
  vim.api.nvim_create_autocmd('BufReadPost', {
    group = group,
    buffer = buf,
    callback = function(args)
      vim.bo[args.buf].modifiable = false
      error('boom-unrestorable')
    end,
  })
  local notes = capture_notify(function() Fs.sync_buffers(old, new) end)
  vim.api.nvim_del_augroup_by_id(group)
  local warn = find_note(notes, vim.log.levels.WARN, 'boom-unrestorable')
  assert(warn, '应有 WARN 带出原始错误，实际 ' .. vim.inspect(notes))
  assert(warn.msg:find('未能完整恢复', 1, true) and not warn.msg:find('已按重读前保存的恢复', 1, true), '恢复不了时 WARN 不能说已恢复: ' .. warn.msg)
  assert(lines_of(buf)[1] == 'changed-on-disk', '前置：恢复确实没写进去')
end

-- 3. 重读期间 autocmd 切走窗口 / 标签页：rundo、winsaveview、winrestview 必须作用在原窗口与原 buffer，
--    不能给别的 buffer 多出 undo 步，也不能丢原窗口的光标与目标 buffer 的 undo 历史
for _, switch in ipairs({ 'wincmd w', 'tabnew' }) do
  local old, new = next_paths('txt')
  local buf = open(old, make_lines(60))
  local win = vim.api.nvim_get_current_win()
  local tab = vim.api.nvim_get_current_tabpage()
  vim.cmd('vsplit')
  vim.cmd('enew')
  local other = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_win(win)

  for _, text in ipairs({ 'A', 'B' }) do
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { text })
    vim.cmd('let &undolevels = &undolevels')
  end
  assert(write(buf) and not vim.bo[buf].modified)
  for _, text in ipairs({ 'other1', 'other2' }) do
    vim.api.nvim_buf_set_lines(other, 0, -1, false, { text })
    in_buf(other, function() vim.cmd('let &undolevels = &undolevels') end)
  end
  vim.api.nvim_win_set_cursor(win, { 40, 0 })
  local function seq(b) return in_buf(b, function() return vim.fn.undotree().seq_cur end) end
  local other_seq = seq(other)

  local group = vim.api.nvim_create_augroup('test_sync_buffers_switch', { clear = true })
  vim.api.nvim_create_autocmd('BufReadPost', {
    group = group,
    callback = function(args)
      if vim.api.nvim_buf_get_name(args.buf) == new then vim.cmd(switch) end
    end,
  })
  assert(vim.uv.fs_rename(old, new))
  Fs.sync_buffers(old, new)
  vim.api.nvim_del_augroup_by_id(group)

  assert(seq(other) == other_seq, switch .. '：别的 buffer 的 undo 不应被动到，期望 seq ' .. other_seq .. ' 实际 ' .. seq(other))
  local tree = in_buf(buf, vim.fn.undotree)
  assert(tree.seq_last == 2 and tree.seq_cur == 2, switch .. '：目标 buffer 的 undo 链应恰好 2 步（rundo 要作用到它），实际 ' .. vim.inspect({ tree.seq_last, tree.seq_cur }))
  assert(vim.api.nvim_win_get_cursor(win)[1] == 40, switch .. '：原窗口光标应恢复到 40，实际 ' .. vim.api.nvim_win_get_cursor(win)[1])
  assert(lines_of(buf)[1] == 'B' and not vim.bo[buf].modified)

  vim.api.nvim_set_current_tabpage(tab)
  vim.cmd('silent! tabonly')
  vim.cmd('silent! only')
end

-- 4. 窗口在重读期间被关闭：视图不恢复（没有窗口可恢复），undo 仍恢复到 buffer，不抛错
do
  local old, new = next_paths('txt')
  local buf = open(old, make_lines(30))
  for _, text in ipairs({ 'A', 'B' }) do
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { text })
    vim.cmd('let &undolevels = &undolevels')
  end
  assert(write(buf))
  vim.cmd('vsplit')
  vim.cmd('enew')
  local other_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(vim.fn.win_findbuf(buf)[1])
  local target_win = vim.api.nvim_get_current_win()
  local group = vim.api.nvim_create_augroup('test_sync_buffers_close', { clear = true })
  vim.api.nvim_create_autocmd('BufReadPost', {
    group = group,
    callback = function(args)
      if vim.api.nvim_buf_get_name(args.buf) == new then
        vim.api.nvim_set_current_win(other_win)
        vim.api.nvim_win_close(target_win, true)
      end
    end,
  })
  assert(vim.uv.fs_rename(old, new))
  assert(pcall(Fs.sync_buffers, old, new), '窗口被关闭不应抛错')
  vim.api.nvim_del_augroup_by_id(group)
  local tree = in_buf(buf, vim.fn.undotree)
  assert(tree.seq_last == 2, '窗口已失效时 undo 仍应恢复到 buffer，实际 seq_last=' .. tree.seq_last)
  vim.cmd('silent! only')
end

-- 5. LSP：`vim.lsp.start` 手动附着的 client 在 `:edit!` 后不会自动重附，要补救；
--    `vim.lsp.enable` + FileType 自动附着的 client 不能因补救而重复附着
do
  local events = { manual = {}, auto = {} }
  local function fake(name)
    return function()
      local id = 0
      return {
        request = function(method, _, callback)
          if method == 'initialize' then
            callback(nil, { capabilities = { textDocumentSync = { openClose = true, change = 2 } } })
          elseif method == 'shutdown' then
            callback(nil, nil)
          end
          id = id + 1
          return true, id
        end,
        notify = function(method, params)
          local td = params and params.textDocument
          local list = events[name]
          list[#list + 1] = { method = method:gsub('^textDocument/', ''), uri = td and td.uri, text = td and td.text }
          return true
        end,
        is_closing = function() return false end,
        terminate = function() end,
      }
    end
  end

  vim.lsp.config('vv_fake_auto', { cmd = fake('auto'), filetypes = { 'lua' }, root_markers = { '.git' } })
  vim.lsp.enable('vv_fake_auto')

  local old, new = next_paths()
  local buf = open(old, { 'local x = 1' })
  assert(vim.wait(2000, function() return #vim.lsp.get_clients({ bufnr = buf, name = 'vv_fake_auto' }) == 1 end), '前置：自动 client 应附着')
  vim.lsp.start({ name = 'vv_fake_manual', cmd = fake('manual'), root_dir = root }, { bufnr = buf })
  assert(vim.wait(2000, function() return #vim.lsp.get_clients({ bufnr = buf, name = 'vv_fake_manual' }) == 1 end), '前置：手动 client 应附着')

  events = { manual = {}, auto = {} }
  assert(vim.uv.fs_rename(old, new))
  Fs.sync_buffers(old, new)
  vim.wait(300)

  local function count(name) return #vim.lsp.get_clients({ bufnr = buf, name = name }) end
  assert(count('vv_fake_manual') == 1, '手动附着的 client 在 sync 后应仍附着，实际 ' .. count('vv_fake_manual'))
  assert(count('vv_fake_auto') == 1, '自动附着的 client 不应重复附着，实际 ' .. count('vv_fake_auto'))
  assert(#vim.lsp.get_clients({ bufnr = buf }) == 2, 'client 总数应为 2')

  local uri = vim.uri_from_fname(new)
  local function for_uri(name, method)
    local out = {}
    for _, e in ipairs(events[name]) do
      if e.uri == uri and (not method or e.method == method) then out[#out + 1] = e end
    end
    return out
  end

  -- 改名前 detach：旧 URI 收到 didClose；新 URI 第一条就是 didOpen，不能对未打开的文档发 didClose
  local manual = for_uri('manual')
  local old_uri = vim.uri_from_fname(old)
  local old_closed = vim.tbl_filter(function(e) return e.uri == old_uri and e.method == 'didClose' end, events.manual)
  assert(#old_closed == 1, '手动 client 应收到旧 URI 的 didClose，实际 ' .. vim.inspect(events.manual))
  assert(manual[1] and manual[1].method == 'didOpen', '手动 client 在新 URI 上第一条应是 didOpen，实际 ' .. vim.inspect(manual))
  assert(#for_uri('manual', 'didOpen') == 1, '手动 client 只应重新 didOpen 一次')
  assert(for_uri('manual', 'didOpen')[1].text == 'local x = 1\n', '补救附着的 didOpen 文本应与 buffer 一致，实际 ' .. vim.inspect(for_uri('manual', 'didOpen')[1].text))
  assert(#for_uri('auto', 'didOpen') == 1, '自动 client 只应在 FileType 重附时 didOpen 一次，实际 ' .. #for_uri('auto', 'didOpen'))

  -- 之后编辑继续同步给手动 client
  events.manual = {}
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { 'local z = 3' })
  vim.wait(2000, function() return #for_uri('manual', 'didChange') > 0 end)
  assert(#for_uri('manual', 'didChange') > 0, '补救附着后的编辑应继续发 didChange')

  -- 已停止的 client 不会被拉起
  local old2, new2 = next_paths()
  local buf2 = open(old2, { 'local y = 1' })
  vim.lsp.start({ name = 'vv_fake_manual2', cmd = fake('manual'), root_dir = root }, { bufnr = buf2 })
  assert(vim.wait(2000, function() return #vim.lsp.get_clients({ bufnr = buf2, name = 'vv_fake_manual2' }) == 1 end))
  local dead = vim.lsp.get_clients({ bufnr = buf2, name = 'vv_fake_manual2' })[1]
  local group = vim.api.nvim_create_augroup('test_sync_buffers_stop', { clear = true })
  vim.api.nvim_create_autocmd('BufReadPost', {
    group = group,
    callback = function(args)
      if vim.api.nvim_buf_get_name(args.buf) == new2 then dead:stop(true) end
    end,
  })
  assert(vim.uv.fs_rename(old2, new2))
  Fs.sync_buffers(old2, new2)
  vim.api.nvim_del_augroup_by_id(group)
  vim.wait(300)
  assert(#vim.lsp.get_clients({ bufnr = buf2, name = 'vv_fake_manual2' }) == 0, '已停止的 client 不应被补救附着')

  vim.lsp.enable('vv_fake_auto', false)
  for _, client in ipairs(vim.lsp.get_clients()) do client:stop(true) end
end

-- BufReadPre 报错后恢复：BOM、CRLF、noeol 这些写盘相关的选项必须原样还原，否则之后 `:w` 写出的文件会
-- 少 BOM、改换行、补末尾换行
do
  local dir = root .. '/opts'
  vim.fn.mkdir(dir, 'p')
  vim.cmd('silent only')
  local file = dir .. '/a.txt'
  local content = '\239\187\191line1\r\nline2'
  local f = assert(io.open(file, 'wb')); f:write(content); f:close()
  vim.cmd('silent edit ' .. vim.fn.fnameescape(file))
  local buf = vim.api.nvim_get_current_buf()
  assert(vim.bo[buf].bomb and vim.bo[buf].fileformat == 'dos' and not vim.bo[buf].endofline, '前置：应识别为 BOM + CRLF + noeol')
  vim.bo[buf].fixendofline = false

  local moved = dir .. '/b.txt'
  vim.uv.fs_rename(file, moved)
  local group = vim.api.nvim_create_augroup('vv-test-opts', { clear = true })
  vim.api.nvim_create_autocmd('BufReadPre', { group = group, pattern = '*/b.txt', callback = function() error('boom') end })
  capture_notify(function() Fs.sync_buffers(file, moved) end)
  vim.api.nvim_del_augroup_by_id(group)

  assert(vim.bo[buf].bomb, '出错恢复必须还原 bomb')
  assert(vim.bo[buf].fileformat == 'dos', '出错恢复必须还原 fileformat')
  assert(not vim.bo[buf].endofline, '出错恢复必须还原 endofline')
  assert(not vim.bo[buf].fixendofline, '出错恢复必须还原 fixendofline')
  vim.bo[buf].readonly = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'line1', 'edited' })
  assert(write(buf, true))
  local out = assert(io.open(moved, 'rb')); local bytes = out:read('*a'); out:close()
  assert(bytes == '\239\187\191line1\r\nedited', '写出的字节必须保留 BOM / CRLF / 无末尾换行: ' .. vim.inspect(bytes))
end

vim.fn.delete(root, 'rf')
print('PASS: test_fs_buffer_recovery')
