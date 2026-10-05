-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  root = vim.env.VV_TEST_REPO
  vim.opt.runtimepath:prepend(root)

  Timer = require('vv-utils.timer')

  function sleep(ms) vim.wait(ms, function() return false end, 5) end
end)

T["默认节流丢弃窗口内调用"] = function()
  child.lua_func(function()
    local plain_calls = {}
    local plain, plain_cancel = Timer.throttle(function(v) plain_calls[#plain_calls + 1] = v end, 60)
    plain('a')
    plain('b')
    sleep(120)
    assert(vim.deep_equal(plain_calls, { 'a' }), '默认 throttle 必须丢弃窗口内调用：' .. vim.inspect(plain_calls))
    plain_cancel()
  end)
end

T["尾随节流保留末次参数并开启新窗口"] = function()
  child.lua_func(function()
    local calls = {}
    local throttled, cancel = Timer.throttle(function(...) calls[#calls + 1] = { ... } end, 60, { trailing = true })
    throttled('first')
    throttled('second')
    throttled('last', nil, 3)
    assert(#calls == 1, '前沿必须立即执行，窗口内不得立即执行')
    assert(vim.wait(2000, function() return #calls == 2 end, 1), '等待第一次尾随执行超时')
    assert(#calls == 2, '窗口结束时必须补执行一次窗口内的调用：' .. vim.inspect(calls))
    assert(calls[2][1] == 'last' and calls[2][2] == nil and calls[2][3] == 3, '补执行必须使用最后一次调用的参数（含 nil 空洞）')

    -- 3：补执行开启了新窗口，紧接着的调用被合并
    throttled('during-trailing-window')
    assert(#calls == 2, '补执行后应处于新窗口，后续调用不得立即执行')
    assert(vim.wait(2000, function() return #calls == 3 end, 1), '等待下一窗口尾随执行超时')
    assert(#calls == 3 and calls[3][1] == 'during-trailing-window', '新窗口内的调用同样在窗口结束时补执行')
    sleep(120)
    assert(#calls == 3, '没有新调用时不得重复补执行')
    cancel()
  end)
end

T["幂等取消丢弃待执行尾随调用"] = function()
  child.lua_func(function()
    local calls = {}
    local throttled, cancel = Timer.throttle(function(...) calls[#calls + 1] = { ... } end, 60, { trailing = true })
    throttled('x')
    throttled('dropped')
    cancel()
    cancel()
    sleep(120)
    assert(#calls == 1 and calls[1][1] == 'x', 'cancel 后不得补执行尾随调用')
  end)
end

return T
