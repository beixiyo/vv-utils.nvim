-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  root = vim.env.VV_TEST_REPO
  vim.opt.runtimepath:prepend(root)

  Clock = require('vv-utils.loading.clock')
  Prompt = require('vv-utils.prompt')

  ---@param interval_ms any
  ---@return table
  function prompt_opts(interval_ms)
    return {
      spinner = { interval_ms = interval_ms },
      on_change = function() end,
      on_accept = function() end,
      on_cancel = function() end,
    }
  end
end)

T["非法 spinner 间隔在创建 UI 前拒绝"] = function()
  child.lua_func(function()
    local anchor = vim.api.nvim_get_current_win()

    for _, bad in ipairs({ 0, -1, 0.5, 1.5, 'x', 0 / 0, math.huge }) do
      local wins = #vim.api.nvim_list_wins()
      local bufs = #vim.api.nvim_list_bufs()
      local ok, err = pcall(Prompt.open, anchor, prompt_opts(bad))
      -- 旧实现下 open 成功：关掉以免影响后续用例，再让断言报出失败
      if ok and err then err.close() end
      assert(not ok, 'interval_ms=' .. tostring(bad) .. ' 时 open 必须抛错')
      assert(tostring(err):find('interval_ms', 1, true), '错误信息必须指明 interval_ms：' .. tostring(err))
      assert(#vim.api.nvim_list_wins() == wins, 'open 失败不得残留浮窗（interval_ms=' .. tostring(bad) .. '）')
      assert(#vim.api.nvim_list_bufs() == bufs, 'open 失败不得残留 buffer（interval_ms=' .. tostring(bad) .. '）')
      assert(Clock._timer_count() == 0, 'open 失败不得残留时钟 timer')
      assert(vim.api.nvim_get_current_win() == anchor, 'open 失败不得改变当前窗口')
    end
  end)
end

T["合法缺省 spinner 间隔关闭后释放时钟"] = function()
  child.lua_func(function()
    local anchor = vim.api.nvim_get_current_win()
    -- 合法值（含缺省）：open 成功，set_busy 正常启动 / 停止 spinner
    for _, good in ipairs({ 1, 80, false }) do
      local handle = assert(Prompt.open(anchor, prompt_opts(good or nil)))
      handle.set_busy(true, 'busy')
      assert(Clock._timer_count() == 1, '合法 interval_ms 时 set_busy(true) 必须启动 spinner')
      handle.close()
      assert(Clock._timer_count() == 0, 'close 必须释放时钟')
    end
  end)
end

return T
