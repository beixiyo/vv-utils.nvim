-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  root = vim.env.VV_TEST_REPO
  vim.opt.runtimepath:prepend(root)

  Loading = require('vv-utils.loading')
  Prompt = require('vv-utils.prompt')
  Clock = require('vv-utils.loading.clock')
end)

T["帧选项拒绝非法类型且 nil 使用默认值"] = function()
  child.lua_func(function()
    local ok_nil, err_nil = pcall(Loading.validate_frame_opts, nil)
    assert(ok_nil, 'opts 为 nil 必须视为全部取默认：' .. tostring(err_nil))

    for _, bad in ipairs({ false, true, 'x', 1 }) do
      local ok, err = pcall(Loading.validate_frame_opts, bad)
      assert(not ok, 'opts=' .. vim.inspect(bad) .. ' 必须抛错')
      assert(tostring(err):find('^vv%-utils%.loading: '), '错误必须带默认前缀：' .. tostring(err))
      local ok2, err2 = pcall(Loading.validate_frame_opts, bad, 'host: ')
      assert(not ok2 and tostring(err2):find('^host: '), '错误必须带调用方前缀：' .. tostring(err2))
    end
  end)
end

T["非法 spinner 在创建 UI 之前失败"] = function()
  child.lua_func(function()
    local anchor = vim.api.nvim_get_current_win()
    for _, bad in ipairs({ false, true, 'x', 1 }) do
      local wins, bufs = #vim.api.nvim_list_wins(), #vim.api.nvim_list_bufs()
      local ok, err = pcall(Prompt.open, anchor, {
        spinner = bad,
        on_change = function() end,
        on_accept = function() end,
        on_cancel = function() end,
      })
      if ok and err then err.close() end
      vim.cmd.stopinsert()
      assert(not ok, 'spinner=' .. vim.inspect(bad) .. ' 时 prompt.open 必须抛错')
      assert(tostring(err) == 'vv-utils.prompt: spinner must be a table', '错误必须精确为 prompt 的 spinner 类型错误：' .. tostring(err))
      assert(#vim.api.nvim_list_wins() == wins and #vim.api.nvim_list_bufs() == bufs, 'open 失败不得残留浮窗 / buffer')
    end
  end)
end

T["合法与缺省 spinner 关闭后释放时钟"] = function()
  child.lua_func(function()
    local anchor = vim.api.nvim_get_current_win()
    for _, spinner in ipairs({ {}, vim.NIL }) do
      local handle = assert(Prompt.open(anchor, {
        spinner = spinner ~= vim.NIL and spinner or nil,
        on_change = function() end,
        on_accept = function() end,
        on_cancel = function() end,
      }))
      handle.close()
      vim.cmd.stopinsert()
    end
    assert(Clock._timer_count() == 0, '不得残留时钟 timer')
  end)
end

return T
