-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  vim.opt.runtimepath:prepend(vim.env.VV_TEST_REPO)
  Git = require('vv-utils.git')
end)

T["diff 源的声明、通知与清除"] = function()
  child.lua_func(function()
    local buf = vim.api.nvim_create_buf(false, true)
    local notified = {}
    vim.api.nvim_create_autocmd('User', {
      pattern = Git.DIFF_SOURCE_EVENT,
      callback = function(args) notified[#notified + 1] = args.data.buf end,
    })

    assert(Git.diff_source(buf) == nil)
    Git.set_diff_source(buf, { root = '/repo', path = 'a.lua', mode = 'staged' })
    assert(Git.diff_source(buf).path == 'a.lua' and notified[1] == buf)

    Git.set_diff_source(buf, nil)
    assert(Git.diff_source(buf) == nil and #notified == 2, '清除也要通知消费方')

    assert(not pcall(Git.set_diff_source, buf, { root = '/repo' }), '缺少 path 的声明应被拒绝')
  end)
end

return T
