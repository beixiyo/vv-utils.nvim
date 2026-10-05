-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  repo = vim.fn.fnamemodify((vim.env.VV_TEST_REPO .. '/tests/test_fs_transaction_async.lua'), ':p:h:h')
  vim.opt.runtimepath:prepend(repo)

  fs = require('vv-utils.fs')
  uv = vim.uv

  function assert_eq(actual, expected, message)
    if actual ~= expected then
      error(string.format('%s：期望 %s，实际 %s', message, vim.inspect(expected), vim.inspect(actual)), 2)
    end
  end

  ---@return table result { ok, err, third, fourth }
  function wait_done(start)
    local result
    local sync = true
    start(function(...) result = { ... }; result.sync = sync end)
    sync = false
    assert(vim.wait(60000, function() return result ~= nil end, 5), 'on_done 未在时限内触发')
    assert(not result.sync, 'on_done 必须异步触发')
    return result
  end

  function memory_transaction(files, write)
    return fs.new_transaction({
      read = function(path) return assert(files[path], 'missing ' .. path) end,
      write = write or function(path, content) files[path] = content end,
      check_modified_buffers = false,
    })
  end
end)

T["真实批量写入与撤回期间让出事件循环"] = function()
  child.lua_func(function()
    local base = vim.fs.normalize(uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname())
    vim.fn.mkdir(base, 'p')
    base = vim.fs.normalize(uv.fs_realpath(base))
    local entries = {}
    for i = 1, 400 do
      local path = string.format('%s/f%03d.txt', base, i)
      fs.write_all(path, 'old ' .. i .. '\n', { fsync = false })
      entries[i] = { path = path, old = 'old ' .. i .. '\n', new = 'new ' .. i .. '\n' }
    end

    local transaction = fs.new_transaction()
    local progress = {}
    local iterations = 0
    local idle = assert(uv.new_idle())
    idle:start(function() iterations = iterations + 1 end)
    local result = wait_done(function(done)
      transaction:apply_async(entries, {
        budget_ms = 0,
        on_progress = function(p) progress[p.step] = p end,
        on_done = done,
      })
    end)
    idle:stop(); idle:close()

    assert(result[1], 'apply_async 应成功：' .. tostring(result[2]))
    assert_eq(result[3], true, '必须报告 touched')
    for _, entry in ipairs(entries) do assert_eq(fs.read_all(entry.path), entry.new, '写入内容：' .. entry.path) end
    assert_eq(progress.apply and progress.apply.done, 400, '写入进度必须达到总数')
    assert_eq(progress.apply.total, 400, '进度总数')
    assert(transaction:can_undo(), 'apply_async 成功后可撤回')
    assert(iterations >= 10, '强制分片写入必须多轮让出事件循环，不能退化为同步写入：' .. iterations)

    -- 5：undo_async 撤回全部文件
    result = wait_done(function(done) transaction:undo_async({ on_done = done }) end)
    assert(result[1], 'undo_async 应成功：' .. tostring(result[2]))
    assert_eq(result[3], 400, '撤回文件数量')
    for _, entry in ipairs(entries) do assert_eq(fs.read_all(entry.path), entry.old, '恢复内容：' .. entry.path) end
    assert(not transaction:can_undo(), 'undo 消费撤回记录')
    vim.fn.delete(base, 'rf')
  end)
end

T["中途失败逆序补偿回滚并报告已写文件"] = function()
  child.lua_func(function()
    local files = { a = 'old-a', b = 'old-b', c = 'old-c', d = 'old-d' }
    local failing = memory_transaction(files, function(path, content)
      if path == 'c' then error('disk full') end
      files[path] = content
    end)
    local steps = {}
    result = wait_done(function(done)
      failing:apply_async({
        { path = 'a', old = 'old-a', new = 'new-a' },
        { path = 'b', old = 'old-b', new = 'new-b' },
        { path = 'c', old = 'old-c', new = 'new-c' },
        { path = 'd', old = 'old-d', new = 'new-d' },
      }, {
        budget_ms = 0,
        on_progress = function(p) steps[#steps + 1] = p.step end,
        on_done = done,
      })
    end)
    assert_eq(result[1], false, '异步写入失败')
    assert(tostring(result[2]):find('disk full', 1, true), '错误必须包含写入失败原因：' .. tostring(result[2]))
    assert_eq(result[3], true, '部分写入后必须报告 touched')
    assert_eq(files.a, 'old-a', '文件 a 必须回滚')
    assert_eq(files.b, 'old-b', '文件 b 必须回滚')
    assert_eq(files.d, 'old-d', '文件 d 不得被写入')
    assert_eq(steps[#steps], 'compensate', '回滚进度必须报告补偿步骤')
    assert(not failing:can_undo() and not failing:is_locked(), '完整回滚后不可撤回、不锁定')
  end)
end

T["让出间隙出现未保存 buffer 时拒绝写入并回滚"] = function()
  child.lua_func(function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local p1, p2 = dir .. '/one.txt', dir .. '/two.txt'
    fs.write_all(p1, 'one\n'); fs.write_all(p2, 'two\n')
    local guarded = fs.new_transaction()
    local dirty_buf
    result = wait_done(function(done)
      guarded:apply_async({
        { path = p1, old = 'one\n', new = 'ONE\n' },
        { path = p2, old = 'two\n', new = 'TWO\n' },
      }, {
        budget_ms = 0,
        on_progress = function(p)
          if p.step == 'apply' and p.done == 1 and not dirty_buf then
            dirty_buf = vim.fn.bufadd(p2)
            vim.fn.bufload(dirty_buf)
            vim.api.nvim_buf_set_lines(dirty_buf, 0, -1, false, { 'unsaved' })
          end
        end,
        on_done = done,
      })
    end)
    assert_eq(result[1], false, '未保存 buffer 必须阻止写入')
    assert(tostring(result[2]):find('unsaved buffer', 1, true), '错误必须指出未保存 buffer：' .. tostring(result[2]))
    assert_eq(fs.read_all(p1), 'one\n', '首个文件必须回滚')
    assert_eq(fs.read_all(p2), 'two\n', '未保存文件不得被修改')
    vim.api.nvim_buf_delete(dirty_buf, { force = true })
    vim.fn.delete(dir, 'rf')
  end)
end

T["在途再次调用拒绝 busy 但保留原事务"] = function()
  child.lua_func(function()
    files = { a = 'old-a', b = 'old-b' }
    local busy_tx = memory_transaction(files)
    local first, second
    busy_tx:apply_async({
      { path = 'a', old = 'old-a', new = 'new-a' },
      { path = 'b', old = 'old-b', new = 'new-b' },
    }, { budget_ms = 0, on_done = function(...) first = { ... } end })
    busy_tx:apply_async({ { path = 'a', old = 'new-a', new = 'x' } }, {
      on_done = function(...) second = { ... } end,
    })
    assert(vim.wait(5000, function() return first and second end, 5), '两个回调都必须执行')
    assert_eq(second[1], false, '在途时再次调用必须被拒绝')
    assert(tostring(second[2]):find('in progress', 1, true), '必须报告 busy：' .. tostring(second[2]))
    assert(first[1], '在途事务仍必须成功：' .. tostring(first[2]))
    assert_eq(files.a .. files.b, 'new-anew-b', '在途写入必须完整完成')
  end)
end

-- 预检结果交付与真正撤回之间让出；验证正常 undo 也保护后来的未保存编辑
T['撤回预检后新增未保存编辑时拒绝写盘并保留撤回记录'] = function()
  child.lua_func(function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local one, two = dir .. '/one.txt', dir .. '/two.txt'
    fs.write_all(one, 'old-one\n')
    fs.write_all(two, 'old-two\n')
    local transaction = fs.new_transaction()
    assert(transaction:apply({
      { path = one, old = 'old-one\n', new = 'new-one\n' },
      { path = two, old = 'old-two\n', new = 'new-two\n' },
    }))

    local dirty
    local result = wait_done(function(done)
      transaction:undo_async({
        budget_ms = 0,
        on_progress = function(progress)
          if progress.step == 'validate' and progress.done == 2 then
            vim.schedule(function()
              dirty = vim.fn.bufadd(one)
              vim.fn.bufload(dirty)
              vim.api.nvim_buf_set_lines(dirty, 0, -1, false, { 'unsaved' })
            end)
          end
        end,
        on_done = done,
      })
    end)

    assert(not result[1] and tostring(result[2]):find('unsaved buffer', 1, true), '正常撤回必须拒绝后来出现的未保存编辑')
    assert_eq(fs.read_all(one), 'new-one\n', '被保护文件的磁盘内容不得撤回')
    assert_eq(fs.read_all(two), 'new-two\n', '已撤回文件必须恢复至事务成功后的内容')
    assert(vim.bo[dirty].modified and vim.deep_equal(vim.api.nvim_buf_get_lines(dirty, 0, -1, false), { 'unsaved' }),
      '未保存的 buffer 必须完整保留')
    assert(transaction:can_undo() and not transaction:is_locked(), '失败撤回应保留可重试的记录')
    vim.api.nvim_buf_delete(dirty, { force = true })
  end)
end

-- 防止把 undo 的写前保护误用到失败恢复，导致正常可恢复的事务被锁定
T['撤回部分完成后遇到未保存编辑仍能恢复已写磁盘'] = function()
  child.lua_func(function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local one, two = dir .. '/one.txt', dir .. '/two.txt'
    fs.write_all(one, 'old-one\n')
    fs.write_all(two, 'old-two\n')
    local transaction = fs.new_transaction()
    assert(transaction:apply({
      { path = one, old = 'old-one\n', new = 'new-one\n' },
      { path = two, old = 'old-two\n', new = 'new-two\n' },
    }))

    local buffers = {}
    local result = wait_done(function(done)
      transaction:undo_async({
        budget_ms = 0,
        on_progress = function(progress)
          if progress.step == 'compensate' and progress.done == 1 then
            for _, path in ipairs({ one, two }) do
              local buf = vim.fn.bufadd(path)
              vim.fn.bufload(buf)
              vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'unsaved' })
              buffers[#buffers + 1] = buf
            end
          end
        end,
        on_done = done,
      })
    end)

    assert(not result[1] and tostring(result[2]):find('unsaved buffer', 1, true), '后续撤回应因未保存编辑失败')
    assert_eq(fs.read_all(one), 'new-one\n', '尚未撤回的文件应保持 new')
    assert_eq(fs.read_all(two), 'new-two\n', '失败恢复不能被新 buffer 编辑拦住，必须恢复已撤回文件的磁盘')
    assert(transaction:can_undo() and not transaction:is_locked(), '成功恢复后保留撤回记录且不锁定')
    for _, buf in ipairs(buffers) do
      assert(vim.bo[buf].modified and vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'unsaved' }),
        '恢复磁盘不应覆盖未保存 buffer')
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)
end

return T
