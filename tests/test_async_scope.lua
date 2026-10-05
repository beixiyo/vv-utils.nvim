-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  source = (vim.env.VV_TEST_REPO .. '/tests/test_async_scope.lua')
  root = vim.fn.fnamemodify(source, ':p:h:h')
  vim.opt.runtimepath:prepend(root)

  Async = require('vv-utils.async')
  function queue()
    local callbacks = {}
    return {
      start = function(callback)
        callbacks[#callbacks + 1] = callback
        return #callbacks
      end,
      resolve = function(index, value)
        callbacks[index](value)
      end,
    }
  end
end)

T["拒绝非表作用域选项"] = function()
  child.lua_func(function()
    do
      local ok = pcall(function() Async.scope(false) end)
      assert(not ok, 'false 不是合法作用域选项表')
    end
  end)
end

T["迟到旧请求不得覆盖最新结果"] = function()
  child.lua_func(function()
    do
      local producer = queue()
      local scope = Async.scope()
      local result

      local request_a = scope:begin()
      producer.start(function(value)
        local current = request_a:finish()
        if current then result = value end
      end)

      local request_b = scope:begin()
      producer.start(function(value)
        local current = request_b:finish()
        if current then result = value end
      end)

      producer.resolve(2, 'B')
      producer.resolve(1, 'A')
      assert(result == 'B', '迟到的旧请求不得覆盖最新结果')
      assert(request_a:reason() == 'superseded')
    end
  end)
end

T["失效后拒绝旧生命周期且允许复用"] = function()
  child.lua_func(function()
    do
      local scope = Async.scope()
      local old_lifecycle = scope:begin()
      scope:invalidate()
      local new_lifecycle = scope:begin()

      assert(not old_lifecycle:is_current(), '宿主失效必须拒绝旧生命周期')
      assert(new_lifecycle:is_current(), '失效后的作用域必须允许复用')
      assert(old_lifecycle:finish() == false)
      assert(old_lifecycle:reason() == 'owner-invalidated')
      assert(new_lifecycle:finish() == true)
    end
  end)
end

T["替换请求物理取消并幂等释放资源"] = function()
  child.lua_func(function()
    do
      local scope = Async.scope({ cancel_previous = true })
      local cancelled = 0
      local disposed = 0
      local old = scope:begin({
        cancel = function() cancelled = cancelled + 1 end,
        dispose = function() disposed = disposed + 1 end,
      })
      local new = scope:begin()

      assert(cancelled == 1, '替换请求必须按配置执行物理取消')
      assert(disposed == 1, '替换请求必须释放调用方资源')
      old:cancel()
      old:dispose()
      assert(cancelled == 1 and disposed == 1, '请求资源清理必须幂等')
      assert(new:is_current(), '旧请求清理不得移除新请求')
      assert(new:finish())
    end
  end)
end

T["同步取消后迟到的资源句柄立即释放"] = function()
  child.lua_func(function()
    do
      local scope = Async.scope()
      local cancelled = 0
      local disposed = 0
      local request = scope:begin()

      scope:cancel()
      request:set_cancel(function() cancelled = cancelled + 1 end)
      request:set_disposer(function() disposed = disposed + 1 end)

      assert(cancelled == 1, '同步取消后迟到的取消句柄必须立即执行')
      assert(disposed == 1, '同步终结后迟到的资源释放必须立即执行')
      assert(not request:is_current(), '取消后的排队回调必须保持过期')
    end
  end)
end

T["取消压制已排队回调的发布"] = function()
  child.lua_func(function()
    do
      local scope = Async.scope()
      local published = false
      local callback_ran = false
      local request = scope:begin()
      vim.schedule(function()
        callback_ran = true
        if request:finish() then published = true end
      end)

      scope:cancel()
      assert(vim.wait(100, function() return callback_ran end, 10),
        '前置：排队回调必须实际执行')
      assert(not published, '已排队的 vim.schedule 回调必须保持逻辑取消')
    end
  end)
end

T["清理重入完成新请求后旧请求不可发布"] = function()
  child.lua_func(function()
    do
      local scope = Async.scope()
      local request_b
      local request_a = scope:begin({
        dispose = function()
          request_b = scope:begin()
          assert(request_b:finish(), '重入请求必须作为最新请求完成')
        end,
      })

      assert(not request_a:finish(),
        '清理回调同步完成新请求后旧请求必须撤销发布')
    end
  end)
end

T["非法请求选项不得改变在途请求"] = function()
  child.lua_func(function()
    do
      local scope = Async.scope({ cancel_previous = true })
      local cancelled = 0
      local request_a = scope:begin({ cancel = function() cancelled = cancelled + 1 end })

      local ok = pcall(function() scope:begin({ cancel = true }) end)
      assert(not ok, '非法取消选项必须被拒绝')
      assert(request_a:is_current() and cancelled == 0,
        '非法请求选项不得改变或取消当前请求')

      ok = pcall(function() scope:begin(false) end)
      assert(not ok and request_a:is_current(), 'false 不是合法请求选项表')
      request_a:finish()
    end
  end)
end

T["同一活动通道不可混用并发模式"] = function()
  child.lua_func(function()
    do
      local scope = Async.scope()
      local latest = scope:begin({ key = 'mixed', mode = 'latest' })
      local ok = pcall(function()
        scope:begin({ key = 'mixed', mode = 'parallel' })
      end)

      assert(not ok, '同一活动通道不得混用 latest 与 parallel 模式')
      assert(latest:is_current() and latest:finish(),
        '拒绝混合模式后不得改变已有通道')

      local parallel = scope:begin({ key = 'mixed', mode = 'parallel' })
      assert(parallel:is_current() and parallel:finish(),
        '已完全释放的键可用其他通道模式复用')
    end
  end)
end

T["非法模式不影响作用域复用"] = function()
  child.lua_func(function()
    do
      local scope = Async.scope()
      local ok = pcall(function() scope:begin({ mode = false }) end)
      assert(not ok, 'mode=false 不得被归一化为 latest')

      local current = scope:begin()
      assert(current:is_current() and current:finish(),
        '非法模式校验不得改变作用域且必须允许复用')
    end
  end)
end

T["不同键的最新请求互不影响"] = function()
  child.lua_func(function()
    do
      local scope = Async.scope()
      local request_a = scope:begin({ key = 'a' })
      local request_b = scope:begin({ key = 'b' })
      assert(request_a:is_current() and request_b:is_current(),
        '不同键的最新请求必须各自独立有效')
      request_a:finish()
      request_b:finish()
    end
  end)
end

T["取消错误无法格式化时仍报告且释放资源"] = function()
  child.lua_func(function()
    do
      local scope = Async.scope()
      local disposed = 0
      local original_notify = vim.notify
      local notification
      vim.notify = function(message) notification = message end
      local bad_error = setmetatable({}, {
        __tostring = function() error('cannot stringify cleanup error') end,
      })
      local request = scope:begin({
        cancel = function() error(bad_error) end,
        dispose = function() disposed = disposed + 1 end,
      })

      local ok = pcall(function() request:cancel() end)
      vim.notify = original_notify
      assert(ok, '清理异常报告不得从取消接口抛出')
      assert(disposed == 1, '取消回调报错不得跳过资源释放')
      assert(notification and notification:find('could not be formatted', 1, true),
        '无法格式化的清理异常仍必须产生安全诊断')
    end
  end)
end

T["同步完成后迟到 disposer 立即释放"] = function()
  child.lua_func(function()
    do
      local scope = Async.scope()
      local cancelled = 0
      local disposed = 0
      local request = scope:begin()

      local function start(callback)
        callback('sync')
        return function() cancelled = cancelled + 1 end,
          function() disposed = disposed + 1 end
      end

      local cancel, dispose = start(function()
        assert(request:finish(), '同步完成时请求仍必须有效')
      end)
      request:set_cancel(cancel)
      request:set_disposer(dispose)

      assert(cancelled == 0, '完成请求不得取消已经结束的 producer')
      assert(disposed == 1, '同步完成后取得的 disposer 必须立即执行')
    end
  end)
end

T["并行请求各自有效并独立完成"] = function()
  child.lua_func(function()
    do
      local scope = Async.scope()
      local first = scope:begin({ mode = 'parallel' })
      local second = scope:begin({ mode = 'parallel' })
      assert(first:is_current() and second:is_current(), '并行请求必须各自独立有效')
      assert(first:finish() and second:finish())
    end
  end)
end

T["逻辑失效资源仍接受宿主物理取消"] = function()
  child.lua_func(function()
    do
      local scope = Async.scope()
      local cancelled = 0
      local request = scope:begin({ cancel = function() cancelled = cancelled + 1 end })
      request:invalidate()
      scope:cancel()

      assert(cancelled == 1, '宿主取消仍必须物理取消已逻辑失效的资源')
    end
  end)
end

T["宿主清理重入仍遍历完整请求快照"] = function()
  child.lua_func(function()
    for _, teardown in ipairs({ 'cancel', 'dispose' }) do
      local scope = Async.scope()
      local cancelled = { a = 0, b = 0, c = 0 }
      local requests = {
        a = scope:begin({ key = 'a' }),
        b = scope:begin({ key = 'b' }),
        c = scope:begin({ key = 'c' }),
      }
      local successor = { a = 'b', b = 'c', c = 'a' }
      for name, request in pairs(requests) do
        request:set_cancel(function()
          cancelled[name] = cancelled[name] + 1
          requests[successor[name]]:finish()
        end)
      end

      local ok = pcall(function() scope[teardown](scope) end)
      assert(ok, teardown .. ' 同步重入不得丢失快照中的后续请求')
      assert(cancelled.a + cancelled.b + cancelled.c == 2,
        teardown .. ' 必须物理取消所有未被其他回调同步完成的请求')
      local owner_reason = teardown == 'dispose' and 'owner-disposed' or 'cancelled'
      local finished = 0
      for _, request in pairs(requests) do
        if request:reason() == 'finished' then
          finished = finished + 1
        else
          assert(request:reason() == owner_reason, teardown .. ' 必须保留宿主终结原因')
        end
      end
      assert(finished == 1, teardown .. ' 必须恰好同步完成一个请求')
    end
  end)
end

T["终态闭包环不保留作用域与请求"] = function()
  child.lua_func(function()
    do
      local retained = setmetatable({}, { __mode = 'v' })
      local function create_terminal_cycle()
        local scope = Async.scope()
        local request
        request = scope:begin({ dispose = function() assert(request) end })
        request:finish()
        retained.request = request
        retained.scope = scope
      end

      create_terminal_cycle()
      for _ = 1, 5 do collectgarbage('collect') end
      assert(retained.request == nil and retained.scope == nil,
        '终态闭包环不得保留请求或作用域')
    end
  end)
end

T["销毁作用域拒绝后续请求"] = function()
  child.lua_func(function()
    do
      local scope = Async.scope()
      local request = scope:begin()
      scope:dispose()

      assert(scope:is_disposed())
      assert(not request:is_current())
      local ok = pcall(function() scope:begin() end)
      assert(not ok, '已销毁的作用域必须拒绝新请求')
    end
  end)
end

return T
