-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  root = vim.env.VV_TEST_REPO
  vim.opt.runtimepath:prepend(root)

  Callback = require('vv-utils.callback')
end)

T["限制调用次数、保留返回值且可幂等禁用"] = function()
  child.lua_func(function()
    local calls = {}
    local invoke = Callback.limit(function(value)
      calls[#calls + 1] = value
      return value, 'returned'
    end, 2)

    local value, marker = invoke('first')
    invoke('second')
    invoke('ignored')
    assert(value == 'first' and marker == 'returned', '包装函数必须保留回调返回值')
    assert(vim.deep_equal(calls, { 'first', 'second' }), '回调必须在达到最大次数后停止执行')

    local disabled_calls = 0
    local disabled, disable = Callback.limit(function() disabled_calls = disabled_calls + 1 end)
    disable()
    disable()
    disabled()
    assert(disabled_calls == 0, 'disable 必须幂等并压制后续调用')

    assert(not pcall(Callback.limit, function() end, 0), '必须拒绝非正数的 max_calls')
  end)
end

return T
