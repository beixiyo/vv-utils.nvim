-- vv-utils.fs.sync_buffers 真实文件 + 真实 buffer 行为测试
-- 契约：未修改的 buffer 改名后重读，:w 不再报 E13，且不破坏 LSP/treesitter、undo 链、mark、编码与换行、readonly；
-- 已修改的 buffer 绝不被重读——内容、undo、mark、jumplist、extmark、光标、磁盘文件原封不动，仅改名（仍会 E13）
local this = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
local plugin_root = vim.fn.fnamemodify(this, ':h:h')

package.path = table.concat({
  plugin_root .. '/lua/?.lua',
  plugin_root .. '/lua/?/init.lua',
  package.path,
}, ';')

-- headless -u NONE 默认不开 filetype 检测，LSP/treesitter 依赖 FileType
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

local function read_bytes(path)
  local f = assert(io.open(path, 'rb'))
  local data = f:read('a')
  f:close()
  return data
end

local function write_bytes(path, data)
  local f = assert(io.open(path, 'wb'))
  f:write(data)
  f:close()
end

local function move(old, new)
  assert(vim.uv.fs_rename(old, new))
  Fs.sync_buffers(old, new)
end

local function make_lines(count)
  local out = {}
  for i = 1, count do out[i] = 'l' .. i end
  return out
end

local ns = vim.api.nvim_create_namespace('test_sync_buffers')

-- 所有“buffer 被动过就会变”的状态，用来断言已修改 buffer 原封不动（不含 buffer 名：改名是预期变化）
local function fingerprint(buf, win)
  return in_buf(buf, function()
    return {
      lines = lines_of(buf),
      modified = vim.bo[buf].modified,
      readonly = vim.bo[buf].readonly,
      changedtick = vim.api.nvim_buf_get_changedtick(buf),
      undotree = vim.fn.undotree(),
      mark_a = vim.api.nvim_buf_get_mark(buf, 'a'),
      jumplist = win and vim.fn.getjumplist(win) or nil,
      changelist = vim.fn.getchangelist(buf),
      extmarks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}),
      cursor = win and vim.api.nvim_win_get_cursor(win) or nil,
      view = win and vim.api.nvim_win_call(win, vim.fn.winsaveview) or nil,
    }
  end)
end

local function assert_e13(buf, label)
  local ok, err = write(buf)
  assert(not ok and tostring(err):find('E13', 1, true), label .. '：已修改 buffer 改名后 :w 应报 E13，实际 ' .. tostring(err))
end

-- 1. 未修改 buffer：改名后 :w 不报 E13
do
  local old, new = root .. '/a.txt', root .. '/a2.txt'
  local buf = open(old, { 'one', 'two' })
  move(old, new)
  assert(vim.api.nvim_buf_get_name(buf) == new, 'buffer 应改名到新路径')
  local ok, err = write(buf)
  assert(ok, '未修改 buffer 改名后 :w 不应失败（E13）: ' .. tostring(err))
  assert(not vim.bo[buf].modified)
end

-- 2. 已修改 buffer 契约：绝不重读。内容/modified/undo/mark/jumplist/changelist/extmark/光标/视图/磁盘全部不变，
--    仅改名；:w 仍报 E13，:w! 可以写（调用方需自行保证磁盘仍是编辑前的内容）
for _, shown in ipairs({ true, false }) do
  local label = shown and '显示中' or '隐藏'
  local old, new = root .. (shown and '/b.txt' or '/bh.txt'), root .. (shown and '/b2.txt' or '/bh2.txt')
  local buf = open(old, make_lines(60))
  local win = vim.api.nvim_get_current_win()
  for _, text in ipairs({ 'A', 'B' }) do
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { text })
    vim.cmd('let &undolevels = &undolevels') -- 每次编辑一个独立的 undo 步
  end
  vim.api.nvim_buf_set_extmark(buf, ns, 44, 1, {})
  vim.api.nvim_win_set_cursor(win, { 40, 0 })
  vim.cmd('normal! ma')
  for _, row in ipairs({ '10', '30', '50', '5' }) do vim.cmd('normal! ' .. row .. 'G') end
  assert(#vim.fn.getjumplist()[1] >= 4, '前置：应有跳转记录')
  if not shown then vim.cmd('enew') end

  local before = fingerprint(buf, shown and win or nil)
  local disk = read_bytes(old)
  assert(vim.uv.fs_rename(old, new))
  Fs.sync_buffers(old, new)

  assert(vim.api.nvim_buf_get_name(buf) == new, label .. '：buffer 应改名')
  assert(vim.deep_equal(fingerprint(buf, shown and win or nil), before), label .. '：已修改 buffer 的状态应原封不动，实际差异见 changedtick/undotree/mark/jumplist')
  assert(read_bytes(new) == disk, label .. '：sync_buffers 不应写盘')

  assert_e13(buf, label)
  assert(read_bytes(new) == disk, label .. '：失败的 :w 不应改动磁盘')
  assert(write(buf, true), label .. '：:w! 应可写')
  assert(vim.deep_equal(vim.fn.readfile(new), lines_of(buf)), label .. '：:w! 后应落盘为 buffer 内容')
end

-- 3. 目录整体改名：已修改的子 buffer 不被重读，未修改的被处理；同前缀兄弟路径不受影响
do
  local dir, newdir = root .. '/d', root .. '/d2'
  vim.fn.mkdir(dir .. '/sub', 'p')
  local clean = open(dir .. '/c.txt', { 'c' })
  local dirty = open(dir .. '/sub/e.txt', { 'e' })
  vim.api.nvim_buf_set_lines(dirty, 0, -1, false, { 'e-dirty' })
  local sibling = open(root .. '/d-keep.txt', { 's' })
  vim.api.nvim_buf_set_lines(sibling, 0, -1, false, { 's-dirty' })

  local dirty_before = fingerprint(dirty)
  local sibling_before = fingerprint(sibling)
  local clean_tick = vim.api.nvim_buf_get_changedtick(clean)
  assert(vim.uv.fs_rename(dir, newdir))
  Fs.sync_buffers(dir, newdir)

  assert(vim.api.nvim_buf_get_name(clean) == newdir .. '/c.txt')
  assert(vim.api.nvim_buf_get_name(dirty) == newdir .. '/sub/e.txt')
  assert(vim.api.nvim_buf_get_name(sibling) == root .. '/d-keep.txt', '同前缀兄弟路径不应改名')
  assert(vim.api.nvim_buf_get_changedtick(clean) ~= clean_tick, '未修改子 buffer 应被重读')
  assert(write(clean), '未修改子 buffer :w 应成功')
  assert(vim.deep_equal(fingerprint(dirty), dirty_before), '已修改子 buffer 不应被重读')
  assert_e13(dirty, '目录改名')
  assert(vim.deep_equal(vim.fn.readfile(newdir .. '/sub/e.txt'), { 'e' }), '已修改子 buffer 不应被写盘')
  assert(write(dirty, true) and vim.deep_equal(vim.fn.readfile(newdir .. '/sub/e.txt'), { 'e-dirty' }))
  assert(vim.deep_equal(fingerprint(sibling), sibling_before), '兄弟 buffer 不应受影响')
end

-- 4. 不相关 buffer 不受影响
do
  local other = open(root .. '/other.txt', { 'o' })
  vim.api.nvim_buf_set_lines(other, 0, -1, false, { 'o-dirty' })
  local before = fingerprint(other)
  local old, new = root .. '/f.txt', root .. '/f2.txt'
  vim.fn.writefile({ 'f' }, old)
  move(old, new)
  assert(vim.api.nvim_buf_get_name(other) == root .. '/other.txt')
  assert(vim.deep_equal(fingerprint(other), before))
end

-- 5. 目标文件不存在（只改名、磁盘无文件）：已修改与未修改都不重读
do
  local old, new = root .. '/g.txt', root .. '/g-missing.txt'
  local dirty = open(old, { 'g' })
  vim.api.nvim_buf_set_lines(dirty, 0, -1, false, { 'g-dirty' })
  Fs.sync_buffers(old, new)
  assert(vim.api.nvim_buf_get_name(dirty) == new)
  assert(lines_of(dirty)[1] == 'g-dirty' and vim.bo[dirty].modified)

  local old2, new2 = root .. '/h.txt', root .. '/h-missing.txt'
  local clean = open(old2, { 'keep1', 'keep2' })
  Fs.sync_buffers(old2, new2)
  assert(vim.api.nvim_buf_get_name(clean) == new2)
  assert(vim.deep_equal(lines_of(clean), { 'keep1', 'keep2' }), '目标不存在时未修改 buffer 不应被重读清空')
end

-- 6. 目标是目录：不重读，仍改名
do
  local old, new = root .. '/i.txt', root .. '/i-dir'
  local buf = open(old, { 'i' })
  vim.fn.mkdir(new)
  Fs.sync_buffers(old, new)
  -- nvim 会给目录名补尾部斜杠
  assert(vim.fs.normalize(vim.api.nvim_buf_get_name(buf)) == new)
  assert(vim.deep_equal(lines_of(buf), { 'i' }), '目标是目录时不应重读')
end

-- 7. 目标存在但不可读：不能被清空，否则之后 :w 会写出空文件（root 下 chmod 000 仍可读，跳过）
do
  local old, new = root .. '/j.txt', root .. '/j2.txt'
  local buf = open(old, { 'secret' })
  assert(vim.uv.fs_rename(old, new))
  vim.uv.fs_chmod(new, 0)
  if not vim.uv.fs_access(new, 'R') then
    Fs.sync_buffers(old, new)
    assert(vim.deep_equal(lines_of(buf), { 'secret' }), '不可读目标不应触发重读清空 buffer')
  else
    print('SKIP: 当前用户可读 chmod 000 文件（root），跳过不可读目标用例')
  end
  vim.uv.fs_chmod(new, tonumber('644', 8))
end

-- 8. buftype 非空的 buffer 不重读（nofile 内容不是磁盘文件）
do
  local old, new = root .. '/k.txt', root .. '/k2.txt'
  vim.fn.writefile({ 'disk' }, new)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.bo[buf].buftype = 'nofile'
  vim.api.nvim_buf_set_name(buf, old)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'mem' })
  Fs.sync_buffers(old, new)
  assert(vim.api.nvim_buf_get_name(buf) == new, 'nofile buffer 仍应改名')
  assert(vim.deep_equal(lines_of(buf), { 'mem' }), 'buftype 非空的 buffer 不应被磁盘内容覆盖')
end

-- 9. 已修改且 nomodifiable：属于已修改，同样不动
do
  local old, new = root .. '/l.txt', root .. '/l2.txt'
  local buf = open(old, { 'disk' })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'dirty' })
  vim.bo[buf].modifiable = false
  local before = fingerprint(buf)
  move(old, new)
  assert(vim.deep_equal(fingerprint(buf), before), 'nomodifiable 的已修改 buffer 应原封不动')
end

-- 10. 未修改且 nomodifiable：仍可重读，modifiable 保持，:w 不报 E13
do
  local old, new = root .. '/m.txt', root .. '/m2.txt'
  local buf = open(old, { 'm' })
  vim.bo[buf].modifiable = false
  move(old, new)
  assert(not vim.bo[buf].modifiable, 'modifiable 应保持关闭')
  assert(write(buf), 'nomodifiable 的未修改 buffer 改名后 :w 不应报 E13')
end

-- 11. 用 ++enc / ++ff 打开的未修改 buffer：重读不能重新探测成乱码或改回 dos
do
  local old, new = root .. '/gbk.txt', root .. '/gbk2.txt'
  local gbk = '\xc4\xe3\xba\xc3\xca\xc0\xbd\xe7\xa3\xac\xd6\xd0\xce\xc4\n'
  write_bytes(old, gbk)
  vim.cmd('silent edit ++enc=cp936 ' .. vim.fn.fnameescape(old))
  local buf = vim.api.nvim_get_current_buf()
  local shown = lines_of(buf)[1]
  assert(shown == '你好世界，中文', '前置：cp936 应解码成中文，实际 ' .. shown)
  move(old, new)
  assert(lines_of(buf)[1] == shown, 'GBK buffer 重读后不应变成 latin1 乱码: ' .. lines_of(buf)[1])
  assert(vim.bo[buf].fileencoding == 'cp936')
  assert(write(buf) and read_bytes(new) == gbk, 'GBK 文件 :w 后字节应不变')

  local old2, new2 = root .. '/crlf.txt', root .. '/crlf2.txt'
  write_bytes(old2, 'a\r\nb\r\n')
  vim.cmd('silent edit ++ff=unix ' .. vim.fn.fnameescape(old2))
  local buf2 = vim.api.nvim_get_current_buf()
  assert(vim.bo[buf2].fileformat == 'unix')
  move(old2, new2)
  assert(vim.bo[buf2].fileformat == 'unix', '++ff=unix 打开的 buffer 重读后不应改回 dos')
  assert(vim.deep_equal(lines_of(buf2), { 'a\r', 'b\r' }))
end

-- 12. 已修改的 CRLF / latin1 / 手动改过 bomb、ff 的 buffer：不重读，选项原样保留，:w! 写盘字节与选项一致
do
  local old, new = root .. '/dc.txt', root .. '/dc2.txt'
  write_bytes(old, 'a\r\nb\r\n')
  vim.cmd('silent edit ' .. vim.fn.fnameescape(old))
  local buf = vim.api.nvim_get_current_buf()
  assert(vim.bo[buf].fileformat == 'dos')
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { 'A' })
  move(old, new)
  assert(write(buf, true))
  assert(read_bytes(new) == 'A\r\nb\r\n', '已修改的 CRLF 文件写盘应保持 CRLF: ' .. vim.inspect(read_bytes(new)))

  local old2, new2 = root .. '/dl.txt', root .. '/dl2.txt'
  write_bytes(old2, 'caf\xe9\n')
  vim.cmd('silent edit ++enc=latin1 ' .. vim.fn.fnameescape(old2))
  local buf2 = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf2, 1, 1, false, { 'new' })
  move(old2, new2)
  assert(write(buf2, true))
  assert(read_bytes(new2) == 'caf\xe9\nnew\n', 'latin1 写盘应保持单字节: ' .. vim.inspect(read_bytes(new2)))

  local old3, new3 = root .. '/opt.txt', root .. '/opt2.txt'
  local buf3 = open(old3, { 'x', 'y' })
  vim.bo[buf3].fileformat = 'dos'
  vim.bo[buf3].bomb = true
  vim.api.nvim_buf_set_lines(buf3, 0, 1, false, { 'X' })
  move(old3, new3)
  assert(vim.bo[buf3].fileformat == 'dos' and vim.bo[buf3].bomb, '手动设置的 ff/bomb 应保持')
  assert(write(buf3, true))
  assert(read_bytes(new3) == '\xef\xbb\xbfX\r\ny\r\n', '写盘应带 BOM 与 CRLF: ' .. vim.inspect(read_bytes(new3)))
end

-- 13. readonly：用户手动 :set ro 的未修改 buffer 重读后必须恢复（重读按文件权限会把它清掉）；
--     已修改 buffer 不重读，ro 与内容原样；普通可写文件不应被误置 readonly
do
  local old, new = root .. '/ro.txt', root .. '/ro2.txt'
  local buf = open(old, { 'r' })
  vim.bo[buf].readonly = true
  move(old, new)
  assert(vim.bo[buf].readonly, '用户手动设置的 readonly 应在重读后恢复')
  assert(not vim.bo[buf].modified)

  local old2, new2 = root .. '/ro-dirty.txt', root .. '/ro-dirty2.txt'
  local buf2 = open(old2, { 'r' })
  vim.api.nvim_buf_set_lines(buf2, 0, -1, false, { 'r-dirty' })
  vim.bo[buf2].readonly = true
  local before = fingerprint(buf2)
  move(old2, new2)
  assert(vim.deep_equal(fingerprint(buf2), before) and vim.bo[buf2].readonly, '已修改且 readonly 的 buffer 应原封不动')

  local old3, new3 = root .. '/rw.txt', root .. '/rw2.txt'
  local buf3 = open(old3, { 'w' })
  move(old3, new3)
  assert(not vim.bo[buf3].readonly, '可写文件重读后不应被置 readonly')
end

-- 14. undo 链：行数超过 undoreload（默认 10000）时 :e! 会清空 undo，小 buffer 会多出一个无效步；
--     都要保证已保存 buffer 的 A→B→C 三步完整、回到原点、redo 可用、临时 undo 文件被清理
for _, count in ipairs({ 5, 20000 }) do
  local old, new = ('%s/u%d.txt'):format(root, count), ('%s/u%dx.txt'):format(root, count)
  local buf = open(old, make_lines(count))
  for _, text in ipairs({ 'A', 'B', 'C' }) do
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { text })
    vim.cmd('let &undolevels = &undolevels')
  end
  assert(write(buf) and not vim.bo[buf].modified)
  local tmpdir = vim.fs.dirname(vim.fn.tempname())
  local before = #vim.fn.readdir(tmpdir)
  move(old, new)
  assert(#vim.fn.readdir(tmpdir) == before, count .. ' 行：临时 undo 文件应被清理')
  assert(not vim.bo[buf].modified)

  local function undo() in_buf(buf, function() vim.cmd('silent undo') end) end
  local function redo() in_buf(buf, function() vim.cmd('silent redo') end) end
  assert(lines_of(buf)[1] == 'C')
  undo()
  assert(lines_of(buf)[1] == 'B', count .. ' 行：第 1 次 undo 应回到 B，实际 ' .. lines_of(buf)[1])
  undo()
  assert(lines_of(buf)[1] == 'A', count .. ' 行：第 2 次 undo 应回到 A，实际 ' .. lines_of(buf)[1])
  undo()
  assert(lines_of(buf)[1] == 'l1', count .. ' 行：第 3 次 undo 应回到最初内容，实际 ' .. lines_of(buf)[1])
  assert(vim.bo[buf].modified, count .. ' 行：撤销到保存点之前应为 modified')
  redo(); redo(); redo()
  assert(lines_of(buf)[1] == 'C' and not vim.bo[buf].modified, count .. ' 行：redo 回保存点应 unmodified')
  assert(vim.fn.undotree().seq_last == 3, count .. ' 行：undo 树不应多出步，实际 seq_last=' .. vim.fn.undotree().seq_last)
end

-- 15. mark / 光标 / 滚动位置：未修改 buffer 重读后保留（:edit! 不调整 mark；topline 会被重置，靠 winrestview 恢复）
do
  local old, new = root .. '/mk.txt', root .. '/mk2.txt'
  local buf = open(old, make_lines(60))
  vim.api.nvim_win_set_cursor(0, { 33, 0 })
  vim.cmd('normal! mb')
  vim.cmd('normal! 7G')
  move(old, new)
  assert(vim.api.nvim_buf_get_mark(buf, 'b')[1] == 33, '未修改 buffer 的 mark 应保留')
  assert(vim.api.nvim_win_get_cursor(0)[1] == 7, '未修改 buffer 的光标应恢复')

  local old3, new3 = root .. '/sc.txt', root .. '/sc2.txt'
  local buf3 = open(old3, make_lines(200))
  vim.api.nvim_win_set_cursor(0, { 150, 0 })
  vim.cmd('normal! zt')
  local topline = vim.fn.winsaveview().topline
  move(old3, new3)
  assert(vim.fn.winsaveview().topline == topline, '滚动位置应恢复，期望 ' .. topline .. ' 实际 ' .. vim.fn.winsaveview().topline)
  assert(vim.api.nvim_win_get_cursor(0)[1] == 150 and vim.api.nvim_get_current_buf() == buf3)
end

-- 16. LSP / treesitter：未修改 buffer 重读后必须重新附着（去掉 noautocmd 的依据）。假 server 记录 didOpen/didClose/didChange；
--     已修改 buffer 不重读，client 不重附、不发 didClose/didOpen
do
  local events = {}
  vim.lsp.config('vv_fake_sync', {
    cmd = function()
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
          events[#events + 1] = { method = method, uri = td and td.uri, text = td and td.text }
          return true
        end,
        is_closing = function() return false end,
        terminate = function() end,
      }
    end,
    filetypes = { 'lua' },
  })
  vim.lsp.enable('vv_fake_sync')
  vim.api.nvim_create_autocmd('FileType', {
    pattern = 'lua',
    callback = function(args) pcall(vim.treesitter.start, args.buf) end,
  })

  local function methods_for(uri)
    local out = {}
    for _, e in ipairs(events) do
      if e.uri == uri then out[#out + 1] = (e.method:gsub('^textDocument/', '')) end
    end
    return out
  end

  for _, case in ipairs({ 'clean', 'hidden', 'dirty' }) do
    local old, new = ('%s/lsp-%s.lua'):format(root, case), ('%s/lsp-%s2.lua'):format(root, case)
    local buf = open(old, { 'local x = 1', 'return x' })
    assert(vim.wait(2000, function() return #vim.lsp.get_clients({ bufnr = buf }) == 1 end), case .. '：前置，LSP 应附着')
    assert(vim.treesitter.highlighter.active[buf], case .. '：前置，treesitter 应启动')
    if case == 'dirty' then vim.api.nvim_buf_set_lines(buf, 0, 1, false, { 'local y = 2' }) end
    if case == 'hidden' then vim.cmd('enew') end

    events = {}
    move(old, new)
    vim.wait(300)

    assert(#vim.lsp.get_clients({ bufnr = buf }) == 1, case .. '：改名后 LSP client 应恰好 1 个，实际 ' .. #vim.lsp.get_clients({ bufnr = buf }))
    assert(vim.treesitter.highlighter.active[buf], case .. '：改名后 treesitter 高亮应存在')
    assert(vim.bo[buf].filetype == 'lua', case .. '：filetype 应保持')

    local got = methods_for(vim.uri_from_fname(new))
    if case == 'dirty' then
      assert(not vim.tbl_contains(got, 'didOpen'), case .. '：已修改 buffer 不重读，不应重新 didOpen，实际 ' .. vim.inspect(got))
      assert_e13(buf, case)
    else
      local close_at, open_at
      for i, m in ipairs(got) do
        if m == 'didClose' then close_at = i end
        if m == 'didOpen' then open_at = i end
      end
      assert(close_at and open_at and close_at < open_at, case .. '：新路径应收到 didClose → didOpen，实际 ' .. vim.inspect(got))
      if case == 'clean' then assert(write(buf), case .. '：:w 不应失败') end
    end

    events = {}
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { 'local z = 3' })
    -- didChange 默认有 150ms 防抖
    vim.wait(2000, function() return #events > 0 end)
    assert(vim.tbl_contains(methods_for(vim.uri_from_fname(new)), 'didChange'), case .. '：之后编辑应继续发 didChange')
  end

  vim.lsp.enable('vv_fake_sync', false)
  for _, client in ipairs(vim.lsp.get_clients()) do client:stop(true) end
end

-- 17. 用户手动置 modified 的 buffer 属于已修改：文本与磁盘一致也不重读，modified 保持
do
  local old, new = root .. '/fm.txt', root .. '/fm2.txt'
  local buf = open(old, { 'same' })
  vim.bo[buf].modified = true
  local before = fingerprint(buf)
  move(old, new)
  assert(vim.deep_equal(fingerprint(buf), before), '手动置 modified 的 buffer 应原封不动')
  assert(vim.bo[buf].modified)
end

-- 18. binary buffer：重读后仍是 binary，内容与无结尾换行保持
do
  local old, new = root .. '/b.bin', root .. '/b2.bin'
  write_bytes(old, 'a\r\nb\0c\r\nz')
  vim.cmd('silent edit ++bin ' .. vim.fn.fnameescape(old))
  local buf = vim.api.nvim_get_current_buf()
  local before = lines_of(buf)
  move(old, new)
  assert(vim.bo[buf].binary and not vim.bo[buf].endofline, 'binary buffer 重读后应保持 binary/noeol')
  assert(vim.deep_equal(lines_of(buf), before))
  assert(write(buf) and read_bytes(new) == 'a\r\nb\0c\r\nz', 'binary 文件 :w 后字节应不变')
end

vim.fn.delete(root, 'rf')
print('PASS: test_fs_buffer_sync')
