-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  root = vim.env.VV_TEST_REPO
  vim.opt.runtimepath:prepend(root)

  Async = require('vv-utils.async')
  uv = vim.uv

  ---同步等待批处理终结并返回 on_done 的结果
  ---@param opts table BatchOpts（含闭包，须在用例内构造）
  ---@return table result
  ---@return string? cancel_kind
  function batch_and_wait(opts)
    local result
    opts.on_done = function(r) result = r end
    Async.batch(opts)
    assert(vim.wait(60000, function() return result ~= nil end, 10), '批处理未在时限内完成')
    return result
  end
end)

T["分片让出事件循环：片间 timer 先于后续项执行"] = function()
  child.lua_func(function()
    -- 捕获分片退化：同步循环或 vim.schedule 自递归会让同一片里跑完全部项，
    -- 片间本该让出的 timer 只能最后执行，主线程被整批独占
    local order = {}
    local result = batch_and_wait({
      items = { 'a', 'b', 'c' },
      budget_items = 1,
      worker = function(item)
        order[#order + 1] = item
        if item == 'a' then
          local timer = assert(uv.new_timer())
          timer:start(0, 0, function()
            timer:stop()
            timer:close()
            order[#order + 1] = 'timer'
          end)
        end
      end,
    })

    assert(result.done == 3 and not result.aborted, '三项应全部处理')
    assert(order[1] == 'a' and order[2] == 'timer',
      '片间必须让出事件循环，timer 应先于第二项执行，实际: ' .. table.concat(order, ','))
  end)
end

T["单项失败与抛错记录后继续且终结结果完整"] = function()
  child.lua_func(function()
    -- 捕获单项失败拖垮整批：err 返回与抛错都应记入 errors 并继续后续项
    local seen = {}
    local result = batch_and_wait({
      items = { 'a', 'b', 'c', 'd' },
      worker = function(item, index)
        seen[#seen + 1] = item
        if item == 'b' then return 'boom-' .. index end
        if item == 'c' then error('thrown') end
      end,
    })

    assert(result.done == 4 and result.total == 4 and not result.aborted, '四项应全部处理')
    assert(table.concat(seen, ',') == 'a,b,c,d', '失败不得中断后续项')
    assert(#result.errors == 2, '应记录两条失败，实际: ' .. #result.errors)
    assert(result.errors[1].item == 'b' and result.errors[1].err == 'boom-2', 'err 返回应带原值')
    assert(result.errors[2].item == 'c' and result.errors[2].err:find('thrown', 1, true),
      '抛错应记为该项失败')
  end)
end

T["is_valid 失效立即停排片并以 aborted 报告"] = function()
  child.lua_func(function()
    -- 捕获过期批处理继续烧 CPU：request 被 supersede 后旧批必须尽快停摆
    local processed = 0
    local result = batch_and_wait({
      items = { 1, 2, 3, 4, 5 },
      budget_items = 1,
      worker = function() processed = processed + 1 end,
      is_valid = function() return processed < 2 end,
    })

    assert(result.aborted, 'is_valid 失效必须报告 aborted')
    assert(result.done == 2 and processed == 2,
      '失效后不得再执行剩余项，实际 done=' .. result.done .. ' processed=' .. processed)
  end)
end

T["cancel 幂等且不再排片、不触发 on_done"] = function()
  child.lua_func(function()
    -- 捕获取消后残片回写：cancel 后不得再执行 worker，也不得触发 on_done
    local function timer_count()
      local count = 0
      uv.walk(function(handle)
        if handle:get_type() == 'timer' and not handle:is_closing() then count = count + 1 end
      end)
      return count
    end
    local before = timer_count()
    local handle
    local processed = {}
    local done_called = false
    handle = Async.batch({
      items = { 'a', 'b', 'c' },
      budget_items = 1,
      worker = function(item) processed[#processed + 1] = item end,
      on_progress = function()
        handle.cancel()
        handle.cancel()
      end,
      on_done = function() done_called = true end,
    })

    vim.wait(200, function() return false end, 10)
    assert(#processed == 1, '取消后不得再执行剩余项，实际: ' .. table.concat(processed, ','))
    assert(not done_called, 'cancel 后不得触发 on_done')
    assert(timer_count() == before, 'progress 内取消后不得重新创建或遗留 timer')
  end)
end

T["worker 内取消立即停止当前片剩余项"] = function()
  child.lua_func(function()
    local handle
    local processed, completed = 0, false
    handle = Async.batch({
      items = { 1, 2, 3 },
      worker = function()
        processed = processed + 1
        handle.cancel()
      end,
      on_done = function() completed = true end,
    })
    vim.wait(100)
    assert(processed == 1 and not completed, 'worker 内取消后不能继续执行当前片或发布结果')
  end)
end

T["空列表与零预算仍异步正常终结"] = function()
  child.lua_func(function()
    -- 捕获两类边界死循环 / 丢回调：空列表要异步回调 on_done；
    -- 预算为 0 时每片必须至少推进一项，否则永远调度不终结
    local empty_done = false
    Async.batch({
      items = {},
      worker = function() end,
      on_done = function(result)
        empty_done = true
        assert(result.done == 0 and result.total == 0 and not result.aborted, '空列表结果应为空且非中止')
      end,
    })
    assert(not empty_done, 'on_done 必须异步触发，不得同步回调')

    local result = batch_and_wait({
      items = { 'a', 'b', 'c' },
      budget_ms = 0,
      budget_items = 1,
      worker = function(item) end,
    })
    assert(result.done == 3 and not result.aborted, '零预算也必须推进并终结')
  end)
end

return T
