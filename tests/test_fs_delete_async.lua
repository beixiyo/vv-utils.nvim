-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  root = vim.env.VV_TEST_REPO
  vim.opt.runtimepath:prepend(root)

  Fs = require('vv-utils.fs')
  uv = vim.uv

  base = vim.fn.tempname()
  vim.fn.mkdir(base, 'p')

  function write(path) vim.fn.mkdir(vim.fs.dirname(path), 'p'); vim.fn.writefile({ 'x' }, path) end

  ---@return boolean ok, string? err
  function delete_and_wait(target)
    local result
    Fs.delete_async(target, { on_done = function(ok, err) result = { ok, err } end })
    assert(vim.wait(60000, function() return result ~= nil end, 10), 'delete_async 未在时限内完成：' .. target)
    return result[1], result[2]
  end
end)

T["删除目录不跟随指向树外的符号链接"] = function()
  child.lua_func(function()
    local outside = base .. '/outside'
    write(outside .. '/keep.txt')
    local tree = base .. '/tree'
    write(tree .. '/a.txt')
    write(tree .. '/sub/b.txt')
    write(tree .. '/sub/deeper/c.txt')
    assert(uv.fs_symlink(outside, tree .. '/link-to-outside'))
    local ok, err = delete_and_wait(tree)
    assert(ok, '删除应成功：' .. tostring(err))
    assert(not uv.fs_lstat(tree), '目标目录必须被完整删除')
    assert(uv.fs_stat(outside .. '/keep.txt'), '符号链接指向的树外内容必须完好（不得跟随链接）')

    -- 父路径归一化不得解析目标本身；目录 symlink 作为根目标且带尾斜杠也只删链接
    local link = base .. '/root-link'
    assert(uv.fs_symlink(outside, link))
    ok, err = delete_and_wait(link .. '/')
    assert(ok and not uv.fs_lstat(link), '根目标 symlink 应只删除链接：' .. tostring(err))
    assert(uv.fs_stat(outside .. '/keep.txt'), '根目标归一化不得删除 symlink 指向的内容')
  end)
end

T["大目录删除期间让出事件循环"] = function()
  child.lua_func(function()
    local big = base .. '/big'
    vim.fn.mkdir(big, 'p')
    for d = 1, 10 do
      vim.fn.mkdir(big .. '/d' .. d, 'p')
      for f = 1, 20 do
        local fd = uv.fs_open(big .. '/d' .. d .. '/f' .. f, 'w', 420)
        uv.fs_close(fd)
      end
    end
    -- 记录删除期间主线程最长被独占多久：分片实现下接近单片预算（8ms），同步实现下等于整个删除耗时
    -- 删除的开始与结束也算作边界：同步实现期间一次 tick 都没有，空档就是整段删除
    local iterations = 0
    local idle = assert(uv.new_idle())
    idle:start(function() iterations = iterations + 1 end)
    local result
    Fs.delete_async(big, {
      budget_ms = 0,
      on_done = function(done, failure) result = { done, failure } end,
    })
    assert(vim.wait(60000, function() return result ~= nil end, 1), '分片删除未完成')
    idle:stop(); idle:close()
    assert(result[1] and not uv.fs_lstat(big), '大目录应完整删除：' .. tostring(result[2]))
    assert(iterations >= 10, '强制分片删除必须多轮让出事件循环，不能退化为同步删除：' .. iterations)
  end)
end

T["不存在目标异步返回成功"] = function()
  child.lua_func(function()
    local sync_called = false
    local missing_result
    Fs.delete_async(base .. '/missing', { on_done = function(o) missing_result = o; sync_called = true end })
    assert(not sync_called, 'on_done 必须异步触发')
    assert(vim.wait(1000, function() return missing_result ~= nil end) and missing_result == true, '目标不存在应视为成功')

    -- 空目标不能经 :p 意外变成 cwd；这是绝对路径归一化新增的重要删除边界
    local cwd = uv.cwd()
    local empty_cwd = base .. '/empty-target'
    write(empty_cwd .. '/keep.txt')
    vim.cmd.cd(empty_cwd)
    local result
    Fs.delete_async('', { on_done = function(ok) result = ok end })
    local was_async = result == nil
    local completed = vim.wait(1000, function() return result ~= nil end)
    vim.cmd.cd(cwd)
    assert(was_async and completed and result == true, '空目标应维持不存在目标的异步成功语义')
    assert(uv.fs_stat(empty_cwd .. '/keep.txt'), '空目标不得删除当前目录或其中的文件')
  end)
end

T["权限不足报告失败并保留后续内容"] = function()
  child.lua_func(function()
    local locked = base .. '/locked'
    write(locked .. '/inner/file.txt')
    uv.fs_chmod(locked .. '/inner', 365) -- 0555：不能删除其中的文件
    ok, err = delete_and_wait(locked)
    uv.fs_chmod(locked .. '/inner', 493) -- 0755：恢复以便清理
    assert(not ok and type(err) == 'string' and err:find('unlink failed', 1, true), '权限不足应报告失败而不是抛错：' .. tostring(err))
    assert(uv.fs_stat(locked .. '/inner/file.txt'), '失败时不得继续删除失败点之后的内容')
  end)
end

T["幂等取消压制回调并保留剩余文件"] = function()
  child.lua_func(function()
    local cancel_dir = base .. '/cancel'
    for i = 1, 3000 do write(cancel_dir .. '/f' .. i) end
    local called = false
    local handle = Fs.delete_async(cancel_dir, { on_done = function() called = true end, budget_ms = 0 })
    handle.cancel()
    handle.cancel()
    vim.wait(300, function() return false end, 10)
    assert(not called, 'cancel 后不得触发 on_done')
    assert(uv.fs_lstat(cancel_dir), 'cancel 后剩余内容保留')
  end)
end

-- 初次 scandir 已拿到旧目录 handle，路径入口却在下一片前被换成树外 symlink
T['分片前目标目录被替换时停止且不删除链接目标内容'] = function()
  child.lua_func(function()
    local tree, moved, outside = base .. '/tree', base .. '/moved', base .. '/outside'
    write(tree .. '/canary.txt')
    write(outside .. '/canary.txt')
    local result
    Fs.delete_async(tree, { budget_ms = 0, on_done = function(ok, err) result = { ok, err } end })
    assert(uv.fs_rename(tree, moved))
    assert(uv.fs_symlink(outside, tree))
    assert(vim.wait(1000, function() return result ~= nil end), '目录替换后应完成失败交付')

    assert(not result[1], '入口不再属于被扫描目录时必须停止删除')
    assert(uv.fs_stat(outside .. '/canary.txt'), '不得沿替换后的中间 symlink 删除树外内容')
    assert(uv.fs_stat(moved .. '/canary.txt'), '旧扫描目录的剩余文件也应保留')
  end)
end

T['分片之间已扫描子目录被替换时停止且保留树外内容'] = function()
  child.lua_func(function()
    local tree, outside, moved = base .. '/tree', base .. '/outside', base .. '/moved-inner'
    local inner = tree .. '/inner'
    write(inner .. '/canary.txt')
    write(outside .. '/canary.txt')
    local scandir = uv.fs_scandir
    local swapped = false
    -- 仍使用真实 scandir；只在子目录 handle 建立后安排一次真实文件系统变更
    uv.fs_scandir = function(path, ...)
      local handle, err = scandir(path, ...)
      if path == inner and handle and not swapped then
        swapped = true
        vim.schedule(function()
          assert(uv.fs_rename(inner, moved))
          assert(uv.fs_symlink(outside, inner))
        end)
      end
      return handle, err
    end

    local ok, err = pcall(function()
      local result
      Fs.delete_async(tree, { budget_ms = 0, on_done = function(done, failure) result = { done, failure } end })
      assert(vim.wait(1000, function() return result ~= nil end), '子目录替换后应完成交付')
      assert(swapped, '前置：必须在真正打开子目录后进行替换')
      assert(not result[1], '已打开的子目录身份变化后必须停止')
      assert(uv.fs_stat(outside .. '/canary.txt'), '子目录入口变为 symlink 也不得删除树外内容')
      assert(uv.fs_stat(moved .. '/canary.txt'), '被移动的原子目录应保留内容')
    end)
    uv.fs_scandir = scandir
    assert(ok, err)
  end)
end

T['相对目标在分片期间切换 cwd 仍只删除原目标'] = function()
  child.lua_func(function()
    local one, two = base .. '/one', base .. '/two'
    write(one .. '/tree/canary.txt')
    write(two .. '/tree/canary.txt')
    local cwd = vim.fn.getcwd()
    vim.cmd.cd(vim.fn.fnameescape(one))
    local result
    Fs.delete_async('tree', { budget_ms = 0, on_done = function(ok, err) result = { ok, err } end })
    vim.cmd.cd(vim.fn.fnameescape(two))
    assert(vim.wait(1000, function() return result ~= nil end), '切换 cwd 后删除应完成交付')
    vim.cmd.cd(vim.fn.fnameescape(cwd))

    assert(result[1] and not uv.fs_lstat(one .. '/tree'), '相对路径必须在入口绑定为原目标')
    assert(uv.fs_stat(two .. '/tree/canary.txt'), '切换 cwd 不得重定向后续分片')
  end)
end

return T
