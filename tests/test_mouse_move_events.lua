-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  vim.opt.runtimepath:prepend(vim.env.VV_TEST_REPO)
  Mouse = require('vv-utils.mouse')
end)

T["mousemoveevent 按持有者计数，最后一个释放时才还原"] = function()
  child.lua_func(function()
    vim.o.mousemoveevent = false
    local release_a = Mouse.hold_move_events()
    local release_b = Mouse.hold_move_events()
    assert(vim.o.mousemoveevent == true)

    -- 先退出的不能关掉仍在使用的那个；重复释放不重复扣减
    release_a()
    release_a()
    assert(vim.o.mousemoveevent == true, '仍有持有者时不得关闭')
    release_b()
    assert(vim.o.mousemoveevent == false, '最后一个释放后还原')

    -- 原本就开着：全部释放后保持开启
    vim.o.mousemoveevent = true
    Mouse.hold_move_events()()
    assert(vim.o.mousemoveevent == true)

    -- 持有期间被外部关掉：释放时不重新打开
    vim.o.mousemoveevent = false
    local release = Mouse.hold_move_events()
    vim.o.mousemoveevent = false
    release()
    assert(vim.o.mousemoveevent == false)
  end)
end

return T
