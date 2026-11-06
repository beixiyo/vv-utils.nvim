-- 验证真实调度合并、owner 重建隔离和异常后可继续刷新，不依赖队列内部字段
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  Async = require('vv-utils.async')
end)

T['突发请求读取最新状态且回调内新请求不丢失'] = function()
  child.lua_func(function()
    local state, seen = 0, {}
    local refresh
    refresh = Async.coalesce({
      run = function()
        Helpers.eq(refresh:get_state(), 'idle', '执行前应解除 pending，不能把运行态当排队态')
        seen[#seen + 1] = state
        if #seen == 1 then
          state = 4
          refresh:request()
          refresh:request()
          Helpers.eq(refresh:get_state(), 'pending', '重入请求应立即反映下一次排队')
        end
      end,
    })

    Helpers.eq(refresh:get_state(), 'idle')
    for value = 1, 3 do
      state = value
      refresh:request()
    end
    Helpers.eq(refresh:get_state(), 'pending')
    Helpers.eq(seen, {}, '首次请求不能同步绘制')
    assert(vim.wait(1000, function() return #seen >= 2 end), '后续刷新未执行')
    Helpers.eq(seen, { 3, 4 }, '突发请求合并且读取最新状态，回调内请求形成后续一次刷新')
    Helpers.eq(refresh:get_state(), 'idle', '后续刷新完成后不能遗留 pending')

    state = 5
    refresh:request()
    assert(vim.wait(1000, function() return #seen >= 3 end), '完成后应可继续请求')
    Helpers.eq(seen, { 3, 4, 5 })
    refresh:dispose()
  end)
end

T['关闭后旧回调失效且不干扰新建 owner'] = function()
  child.lua_func(function()
    local seen = {}
    local old = Async.coalesce({ run = function() seen[#seen + 1] = '旧' end })
    old:request()
    old:dispose()
    old:dispose()
    old:request()
    Helpers.eq(old:get_state(), 'disposed', '排队期间关闭应立即报告 disposed')

    local current = Async.coalesce({ run = function() seen[#seen + 1] = '新' end })
    current:request()
    current:request()
    local drained = false
    vim.schedule(function() drained = true end)
    assert(vim.wait(1000, function() return drained end), '排队回调未结束')
    Helpers.eq(seen, { '新' }, '只有新 owner 可刷新，旧 handle 不得复活')
    Helpers.eq(old:get_state(), 'disposed', '失效回调出队不得让旧 owner 变回 idle')
    current:dispose()
  end)
end

T['回调异常按调度边界报告且后续请求仍可执行'] = function()
  child.lua_func(function()
    local calls = 0
    local refresh = Async.coalesce({
      run = function()
        calls = calls + 1
        if calls == 1 then
          error('预期合并刷新失败')
        end
      end,
    })

    refresh:request()
    assert(vim.wait(1000, function() return #Helpers.errors > 0 end), '异常不能被合并器吞掉')
    assert(#Helpers.errors == 1 and Helpers.errors[1]:find('预期合并刷新失败', 1, true),
      '应只报告该次预期异常')
    Helpers.errors = {}
    Helpers.eq(refresh:get_state(), 'idle', '异常后不能残留 pending')

    refresh:request()
    assert(vim.wait(1000, function() return calls == 2 end), '异常后 pending 必须释放')
    refresh:dispose()
  end)
end

return T
