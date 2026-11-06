-- 真实 new_work + 文件门闩：不靠睡眠猜完成顺序；所有退出路径等真实 after_work
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  Async = require('vv-utils.async')
  vim.opt.runtimepath:prepend(vim.env.VV_TEST_REPO .. '/tests/fixtures/worker_task')
  worker_task_main_only = true
  Stats = { queued = 0, arrived = 0 }
  local new_work = vim.uv.new_work
  RealNewWork = new_work
  vim.uv.new_work = function(work, after)
    local context = new_work(work, function(...)
      after(...)
      -- after 内 schedule_wrap 已入队；本标记排在生产 receive 后，保证真实回调已处理
      vim.schedule(function() Stats.arrived = Stats.arrived + 1 end)
    end)
    return {
      queue = function(_, ...)
        local ok, err = context:queue(...)
        if ok then
          Stats.queued = Stats.queued + 1
        end
        return ok, err
      end,
    }
  end

  function Wait(predicate, message)
    assert(vim.wait(3000, predicate, 1), message)
  end

  function Release(index)
    vim.fn.writefile({ 'release' }, vim.env.VV_TEST_TMP .. '/release-' .. index)
  end

  function Started(index)
    return vim.uv.fs_stat(vim.env.VV_TEST_TMP .. '/started-' .. index) ~= nil
  end

  function Input(index)
    return { root = vim.env.VV_TEST_TMP, value = index }
  end

  function RunScenario(run)
    local ok, err = xpcall(run, debug.traceback)
    -- 断言失败也必须放行仍在途的真实 worker，然后等待实际 after_work，不能强退 child
    for index = 1, 8 do
      Release(index)
    end
    local drained = vim.wait(6000, function() return Stats.arrived == Stats.queued end, 1)
    assert(drained, '退出前必须等全部真实 worker 完成')
    assert(ok, err)
  end
end)

-- 捕获：初始化偷跑、重复 start、按批次而非动态补位、无界派发、按完成序存结果、主循环阻塞
T['真实线程动态补位有界且乱序完成按输入回填'] = function()
  child.lua_func(function()
    RunScenario(function()
      local prepared, order, progress, done = {}, {}, {}, {}
      local pulses = 0
      local task = Async.worker_task({
        total = 4,
        concurrency = 2,
        worker = 'worker_task_fixture',
        input = function(index)
          prepared[#prepared + 1] = index
          local value = Input(index)
          if index == 1 then value.diff = true end
          if index == 2 then value.value = false end
          if index == 3 then value.value = '二\0三' end
          if index == 4 then value.value = nil end
          return value
        end,
        on_done = function(result) done[#done + 1] = result end,
      })
      task:on('item', function(event)
        order[#order + 1] = event.index
        Helpers.eq(event.completed, #order, '每次 item 必须先记录完成计数')
      end)
      task:on('progress', function(event)
        Helpers.eq(event.completed, #order, 'progress 必须在 item 后通知')
        progress[#progress + 1] = event.progress
      end)
      Helpers.eq(task:get_state(), 'idle')
      Helpers.eq(task:get_result(), nil)
      Helpers.eq(Stats.queued, 0, '创建时不能启动工作')
      Helpers.eq(prepared, {})
      local idle_turn = false
      vim.schedule(function() idle_turn = true end)
      Wait(function() return idle_turn end, '创建后必须能空闲推进事件循环')
      Helpers.eq(Stats.queued, 0, '创建后经过调度轮次也不能偷跑')
      Helpers.eq(prepared, {}, '未 start 不能准备输入')
      Helpers.eq(task:get_state(), 'idle')
      task:start()
      task:start()
      Helpers.eq(task:get_state(), 'running')
      Helpers.eq(prepared, {}, 'start 必须异步准备输入')
      local timer = assert(vim.uv.new_timer())
      timer:start(0, 2, function() pulses = pulses + 1 end)
      local ok, err = pcall(function()
        Wait(function() return Started(1) and Started(2) and pulses >= 2 end, 'worker 执行中主循环必须推进')
        Helpers.eq(prepared, { 1, 2 }, '在途不能超过 concurrency')
        Release(2)
        Wait(function() return Started(3) end, '空闲槽必须在慢项结束前动态领取第三项')
        Helpers.eq(order, { 2 })
        Helpers.eq(prepared, { 1, 2, 3 }, '补位不能超过空闲槽数')
        Release(3)
        Wait(function() return Started(4) end, '同一槽必须可再次领取')
        Release(4)
        Wait(function() return #order == 3 end, '快项不能等待首项再发布')
        Helpers.eq(task:get_result(), nil, '终态前没有最终快照')
        Release(1)
        Wait(function() return #done == 1 end, '最终回调未到达')
        Helpers.eq(order, { 2, 3, 4, 1 })
        Helpers.eq(progress, { 0.25, 0.5, 0.75, 1 })
        Helpers.eq(done[1].results, { { { 1, 1, 1, 1 } }, false, '二\0三', vim.NIL },
          '依赖模块中的真实 diff、false、二进制字符串与 nil 必须保序往返')
        Helpers.eq(done[1].completed, 4)
        Helpers.eq(done[1].state, 'completed')
        assert(task:get_result() == done[1], '终态快照不应深拷贝大结果')
        task:start()
        task:cancel()
        Helpers.eq(task:get_state(), 'completed', '终态不得复活或翻转')
        Helpers.eq(Stats.queued, 4, '重复 start 不能重复派发')
      end)
      timer:stop()
      timer:close()
      assert(ok, err)
    end)
  end)
end

-- 捕获：空任务除零/未完成、取消前启动、完成通知同步重入、终态重复通知
T['空任务与启动前取消只通知一次终态'] = function()
  child.lua_func(function()
    RunScenario(function()
      local done, progress = {}, {}
      local task = Async.worker_task({ total = 0, worker = 'worker_task_fixture', input = Input,
        on_done = function(result) done[#done + 1] = result end })
      task:on('progress', function(event) progress[#progress + 1] = event end)
      task:start()
      task:start()
      Helpers.eq(done, {})
      Wait(function() return #done == 1 end, '空任务必须异步完成')
      Helpers.eq(progress, { { completed = 0, total = 0, progress = 1 } })
      Helpers.eq(done[1], { state = 'completed', completed = 0, total = 0, results = {} })
      local cancelled
      local other = Async.worker_task({ total = 1, worker = 'worker_task_fixture', input = Input,
        on_done = function(result) cancelled = result end })
      other:cancel()
      other:cancel()
      other:start()
      Helpers.eq(cancelled, nil, '取消终态通知也必须 scheduled')
      Wait(function() return cancelled ~= nil end, '取消必须通知终态')
      Helpers.eq(cancelled.state, 'cancelled')
      assert(cancelled.error, '取消必须有原因')
      Helpers.eq(Stats.queued, 0, '取消后 start 不能派发')
    end)
  end)
end

-- 捕获：worker 抛错/结果不可编码失去诊断或卡住，失败后继续派发/发布，订阅残留
for _, failure in ipairs({ 'worker', 'result' }) do
  T['后台失败停止派发并释放订阅：' .. failure] = function()
    child.lua_func(function(kind)
      RunScenario(function()
        local done, items, prepared = {}, {}, {}
        local task = Async.worker_task({ total = 3, concurrency = 2, worker = 'worker_task_fixture',
          input = function(index)
            prepared[#prepared + 1] = index
            local value = Input(index)
            if index == 1 then
              value.fail, value.bad_result = kind == 'worker', kind == 'result'
            end
            return value
          end,
          on_done = function(result) done[#done + 1] = result end })
        local callback = function(event) items[#items + 1] = event end
        local weak = setmetatable({ callback }, { __mode = 'v' })
        local unsubscribe = task:on('item', callback)
        callback = nil
        task:start()
        Wait(function() return Started(1) and Started(2) end, '两项必须真实在途')
        Release(1)
        Wait(function() return #done == 1 end, '失败必须完成收尾')
        Helpers.eq(done[1].state, 'failed')
        assert(done[1].error:find('item 1', 1, true), '失败必须定位索引')
        assert(done[1].error:find('stack traceback', 1, true), '后台异常必须保留堆栈')
        if kind == 'worker' then
          assert(done[1].error:find('预期 worker 失败', 1, true), '必须保留后台错误消息')
        end
        collectgarbage('collect')
        assert(weak[1] == nil, '终态必须解除订阅闭包引用，即使退订句柄仍被持有')
        unsubscribe()
        unsubscribe()
        task:on('item', function() error('终态不能接受新通知') end)
        Release(2)
        Wait(function() return Stats.arrived == 2 end, '失败后也要等真实在途工作结束')
        Helpers.eq(items, {}, '失败后的迟到结果不得发布')
        Helpers.eq(done[1].results, {}, '迟到结果不得修改终态快照')
        Helpers.eq(prepared, { 1, 2 }, '失败后不能准备第三项')
        Helpers.eq(#done, 1)
        task:start()
        task:cancel()
        Helpers.eq(task:get_state(), 'failed')
      end)
    end, failure)
  end
end

-- 捕获：输入准备/编码异常发生在已有工作在途时，不能漏终态或继续启动后续项
for _, failure in ipairs({ 'input', 'encode' }) do
  T['输入失败不影响在途回收且不再派发：' .. failure] = function()
    child.lua_func(function(kind)
      RunScenario(function()
        local prepared, done = {}, nil
        local task = Async.worker_task({ total = 3, concurrency = 2, worker = 'worker_task_fixture',
          input = function(index)
            prepared[#prepared + 1] = index
            if index == 2 then
              if kind == 'input' then error('预期输入失败') end
              return function() end
            end
            return Input(index)
          end,
          on_done = function(result) done = result end })
        task:start()
        Wait(function() return done ~= nil end, '输入错误必须终结')
        Helpers.eq(done.state, 'failed')
        assert(done.error:find('input/queue 2', 1, true), '输入错误必须有派发索引')
        Helpers.eq(prepared, { 1, 2 })
        Helpers.eq(Stats.queued, 1, '不可编码输入不能进入线程池')
        Release(1)
        Wait(function() return Stats.arrived == 1 end, '已派发工作必须真实结束')
        Helpers.eq(done.results, {})
        Helpers.eq(done.completed, 0)
      end)
    end, failure)
  end
end

-- 捕获：监听器异常后仍通知后续订阅/补位，或 item 记录晚于通知导致已完成结果丢失
for _, event in ipairs({ 'item', 'progress' }) do
  T['同步订阅异常快速失败且保留已记录结果：' .. event] = function()
    child.lua_func(function(name)
      RunScenario(function()
        local done, later, prepared = nil, 0, {}
        local task = Async.worker_task({ total = 3, concurrency = 2, worker = 'worker_task_fixture',
          input = function(index) prepared[#prepared + 1] = index; return Input(index) end,
          on_done = function(result) done = result end })
        task:on(name, function() error('预期订阅失败') end)
        task:on(name, function() later = later + 1 end)
        task:start()
        Wait(function() return Started(1) and Started(2) end, '需要在途并发工作')
        Release(2)
        Wait(function() return done ~= nil end, '监听异常必须终结控制器')
        Helpers.eq(done.state, 'failed')
        assert(done.error:find('预期订阅失败', 1, true), '订阅错误必须可诊断')
        Helpers.eq(done.results, { [2] = 2 }, '必须先回填再通知；失败结果允许稀疏')
        Helpers.eq(done.completed, 1)
        Helpers.eq(later, 0, '抛错后不能继续通知同批订阅')
        Release(1)
        Wait(function() return Stats.arrived == 2 end, '不能在真实后台工作结束前退出')
        Helpers.eq(done.results, { [2] = 2 }, '失败快照不得被迟到结果修改')
        Helpers.eq(prepared, { 1, 2 })
      end)
    end, event)
  end
end

-- 捕获：监听内退订/重入取消不能阻止后续通知，取消后迟到结果写入，完成回调异常被吞
T['监听内退订取消抑制迟到发布且完成异常按调度报告'] = function()
  child.lua_func(function()
    RunScenario(function()
      local done, later, progress = 0, 0, 0
      local task = Async.worker_task({ total = 3, concurrency = 2, worker = 'worker_task_fixture', input = Input,
        on_done = function(result)
          done = done + 1
          Helpers.eq(result.state, 'cancelled')
          error('预期完成回调失败')
        end })
      local unsubscribe
      task:on('item', function()
        unsubscribe()
        unsubscribe()
        task:cancel()
        task:cancel()
      end)
      unsubscribe = task:on('item', function() later = later + 1 end)
      task:on('progress', function() progress = progress + 1 end)
      task:start()
      Wait(function() return Started(1) and Started(2) end, '需要真实在途工作')
      Release(1)
      Wait(function() return done == 1 and #Helpers.errors == 1 end, '完成异常必须从调度边界报告')
      assert(Helpers.errors[1]:find('预期完成回调失败', 1, true), '不能吞掉或替换完成错误')
      Helpers.errors = {}
      local snapshot = task:get_result()
      Helpers.eq(snapshot.results, { 1 })
      Helpers.eq(snapshot.completed, 1)
      Helpers.eq(later, 0)
      Helpers.eq(progress, 0, 'item 内取消后不能通知 progress')
      Release(2)
      Wait(function() return Stats.arrived == 2 end, '取消不能伪装物理终止 worker')
      Helpers.eq(snapshot.results, { 1 }, '取消后迟到结果不发布或修改快照')
      Helpers.eq(Stats.queued, 2, '取消后不能派发第三项')
      task:start()
      Helpers.eq(task:get_state(), 'cancelled', '完成回调异常不得翻转终态')
      Helpers.eq(done, 1)
    end)
  end)
end

-- 捕获真实泄漏：第一项完成后在补位 input 中取消，旧 context 不得经回调引用保活
T['动态补位准备输入时取消仍回收真实 work context'] = function()
  child.lua_func(function()
    RunScenario(function()
      local weak = setmetatable({}, { __mode = 'v' })
      vim.uv.new_work = function(work, after)
        local context = RealNewWork(work, function(...)
          after(...)
          vim.schedule(function() Stats.arrived = Stats.arrived + 1 end)
        end)
        -- 返回真实 userdata，不用 table wrapper 掩盖 luv registry 引用环
        weak[1] = context
        Stats.queued = Stats.queued + 1
        return context
      end
      Release(1)
      local function run()
        local task, result
        task = Async.worker_task({ total = 2, concurrency = 1, worker = 'worker_task_fixture',
          input = function(index)
            if index == 2 then task:cancel() end
            return Input(index)
          end,
          on_done = function(outcome) result = outcome end })
        task:start()
        Wait(function() return result ~= nil and Stats.arrived == 1 end, '取消与实际 work 回调必须结束')
        Helpers.eq(result.state, 'cancelled')
        Helpers.eq(result.completed, 1)
        assert(not Started(2), '取消的补位输入不得提交给线程池')
      end
      run()
      for _ = 1, 4 do collectgarbage('collect') end
      assert(weak[1] == nil, '动态补位取消后真实 work context 必须可回收')
    end)
  end)
end

return T
