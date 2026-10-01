-- vv-utils.fs.sync_buffers 的边界：目标是命名管道（FIFO）不能卡死 nvim；
-- BufFilePost 里 wipe 掉 buffer 不能让 sync_buffers 抛错或中断其余 buffer
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

local function write(buf, bang)
  return pcall(vim.api.nvim_buf_call, buf, function() vim.cmd(bang and 'silent write!' or 'silent write') end)
end

local function capture_notify(fn)
  local notes = {}
  local orig = vim.notify
  vim.notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
  local ok, err = pcall(fn)
  vim.notify = orig
  return ok, err, notes
end

-- 1. 目标是 FIFO：filereadable 对它返回 1，`:edit!` 读命名管道会永久阻塞 nvim
--    阻塞时主线程里的 timer 触发不了，所以看门狗放在外部进程：5 秒后 SIGKILL 当前 nvim，
--    测试失败表现为进程被杀（run.sh 判定 FAIL）而不是整个测试套件挂死
do
  local made = vim.system({ 'mkfifo', root .. '/probe-pipe' }):wait()
  if made.code ~= 0 then
    print('SKIP: mkfifo 不可用，跳过 FIFO 用例: ' .. tostring(made.stderr))
  else
    local seq = 0

    for _, kind in ipairs({ 'FIFO', '指向 FIFO 的软链接' }) do
      for _, dirty in ipairs({ false, true }) do
        -- 每个用例用独立的目标路径：两个 buffer 不能同名
        seq = seq + 1
        local target = ('%s/pipe%d'):format(root, seq)
        if kind == 'FIFO' then
          assert(vim.system({ 'mkfifo', target }):wait().code == 0)
        else
          local real = target .. '-real'
          assert(vim.system({ 'mkfifo', real }):wait().code == 0)
          assert(vim.uv.fs_symlink(real, target))
        end
        local case = { name = kind, target = target }
        local label = case.name .. (dirty and '（已修改）' or '（未修改）')
        local old = ('%s/fifo-src%d.txt'):format(root, seq)
        local buf = open(old, { 'keep' })
        if dirty then vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'keep-dirty' }) end
        local want = lines_of(buf)

        local watchdog = vim.system({ 'sh', '-c', ('sleep 5; kill -9 %d'):format(vim.fn.getpid()) })
        local ok, err, notes = capture_notify(function() Fs.sync_buffers(old, case.target) end)
        watchdog:kill(9)

        assert(ok, label .. '：sync_buffers 不应抛错: ' .. tostring(err))
        assert(#notes == 0, label .. '：不应有通知，实际 ' .. vim.inspect(notes))
        assert(vim.fs.normalize(vim.api.nvim_buf_get_name(buf)) == vim.fs.normalize(case.target), label .. '：buffer 仍应改名')
        assert(vim.deep_equal(lines_of(buf), want), label .. '：buffer 保持改名后的原样')
        assert(vim.bo[buf].modified == dirty)
      end
    end
  end
end

-- 2. BufFilePost 里 wipe 当前 buffer：sync_buffers 不能抛 Invalid buffer id
do
  local old, new = root .. '/w.txt', root .. '/w2.txt'
  local buf = open(old, { 'w' })
  assert(vim.uv.fs_rename(old, new))
  local group = vim.api.nvim_create_augroup('test_sync_buffers_wipe', { clear = true })
  vim.api.nvim_create_autocmd('BufFilePost', {
    group = group,
    callback = function(args) vim.cmd('silent! bwipeout! ' .. args.buf) end,
  })
  local ok, err, notes = capture_notify(function() Fs.sync_buffers(old, new) end)
  vim.api.nvim_del_augroup_by_id(group)
  assert(ok, 'BufFilePost 里 wipe 当前 buffer 时 sync_buffers 不应抛错: ' .. tostring(err))
  assert(#notes == 0, '不应有通知，实际 ' .. vim.inspect(notes))
  assert(not vim.api.nvim_buf_is_valid(buf), '前置：buffer 应已被 wipe')
end

-- 3. 目录批量改名时，BufFilePost 里 wipe 掉当前与一个尚未处理的 buffer：其余 buffer 照常处理，不抛错
do
  local dir, newdir = root .. '/wd', root .. '/wd2'
  vim.fn.mkdir(dir, 'p')
  local first = open(dir .. '/1.txt', { '1' })
  local second = open(dir .. '/2.txt', { '2' })
  local third = open(dir .. '/3.txt', { '3' })
  local fourth = open(dir .. '/4.txt', { '4' })
  vim.api.nvim_buf_set_lines(fourth, 0, -1, false, { '4-dirty' })
  assert(vim.uv.fs_rename(dir, newdir))

  local group = vim.api.nvim_create_augroup('test_sync_buffers_wipe_many', { clear = true })
  vim.api.nvim_create_autocmd('BufFilePost', {
    group = group,
    callback = function(args)
      if args.buf == first then
        vim.cmd('silent! bwipeout! ' .. first)
        vim.cmd('silent! bwipeout! ' .. second)
      end
    end,
  })
  local ok, err = capture_notify(function() Fs.sync_buffers(dir, newdir) end)
  vim.api.nvim_del_augroup_by_id(group)

  assert(ok, '批量改名中途 buffer 被 wipe 时不应抛错: ' .. tostring(err))
  assert(not vim.api.nvim_buf_is_valid(first) and not vim.api.nvim_buf_is_valid(second), '前置：前两个 buffer 应已被 wipe')
  assert(vim.api.nvim_buf_get_name(third) == newdir .. '/3.txt', '后面的 buffer 应继续处理')
  assert(vim.api.nvim_buf_get_name(fourth) == newdir .. '/4.txt', '后面的已修改 buffer 应继续处理')
  assert(write(third), '后面的未修改 buffer 应已重读，:w 不报 E13')
  assert(lines_of(fourth)[1] == '4-dirty' and vim.bo[fourth].modified)
end

-- 重读期间 autocmd 把当前 buffer 切到另一个已修改的 buffer：`:edit!` 读完会把「当前 buffer」标成未修改，
-- 那个无关 buffer 的未保存标记不能因此被清掉（否则 :qa 不再提醒，autoread 还可能覆盖它）
for _, action in ipairs({ 'wincmd p', 'wincmd w', 'close' }) do
  local dir = root .. '/switch-' .. action:gsub('%s', '_')
  vim.fn.mkdir(dir, 'p')
  vim.cmd('silent only')
  local unrelated = open(dir .. '/unrelated.txt', { 'unrelated' })
  vim.api.nvim_buf_set_lines(unrelated, 0, -1, false, { 'unrelated', 'USER UNSAVED' })
  assert(vim.bo[unrelated].modified)

  vim.cmd('silent split')
  local victim = open(dir .. '/victim.txt', { 'victim' })
  assert(not vim.bo[victim].modified)
  local moved = dir .. '/moved.txt'
  vim.uv.fs_rename(dir .. '/victim.txt', moved)

  local group = vim.api.nvim_create_augroup('vv-test-switch-' .. action:gsub('%s', '_'), { clear = true })
  vim.api.nvim_create_autocmd('BufReadPost', {
    group = group,
    pattern = '*/moved.txt',
    callback = function() vim.cmd(action) end,
  })
  local ok, err = capture_notify(function() Fs.sync_buffers(dir .. '/victim.txt', moved) end)
  vim.api.nvim_del_augroup_by_id(group)

  assert(ok, tostring(err))
  assert(vim.bo[unrelated].modified, action .. ': 重读期间被切到的另一个已修改 buffer 不能被清掉 modified')
  assert(lines_of(unrelated)[2] == 'USER UNSAVED', action .. ': 其内容也不能变')
end

-- BufFilePost 里把已修改 buffer 设成未修改：以改名前的状态为准，仍不能重读，否则未保存内容会被磁盘覆盖
do
  local dir = root .. '/nomodified'
  vim.fn.mkdir(dir, 'p')
  vim.cmd('silent only')
  local buf = open(dir .. '/a.txt', { 'disk' })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'USER UNSAVED' })
  assert(vim.bo[buf].modified)
  local moved = dir .. '/b.txt'
  vim.uv.fs_rename(dir .. '/a.txt', moved)

  local group = vim.api.nvim_create_augroup('vv-test-nomodified', { clear = true })
  vim.api.nvim_create_autocmd('BufFilePost', {
    group = group,
    callback = function(args) vim.bo[args.buf].modified = false end,
  })
  local ok, err = capture_notify(function() Fs.sync_buffers(dir .. '/a.txt', moved) end)
  vim.api.nvim_del_augroup_by_id(group)

  assert(ok, tostring(err))
  assert(lines_of(buf)[1] == 'USER UNSAVED', 'BufFilePost 清掉 modified 后，未保存内容也不能被重读覆盖')
end

vim.fn.delete(root, 'rf')
print('PASS: test_fs_buffer_edge')
