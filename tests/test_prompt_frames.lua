-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  root = vim.env.VV_TEST_REPO
  vim.opt.runtimepath:prepend(root)

  Clock = require('vv-utils.loading.clock')
  Loading = require('vv-utils.loading')
  Prompt = require('vv-utils.prompt')

  ---@param frames any
  ---@return table
  function prompt_opts(frames)
    return {
      spinner = { frames = frames },
      on_change = function() end,
      on_accept = function() end,
      on_cancel = function() end,
    }
  end
end)

T["非法帧在入口拒绝且不残留 UI 与时钟"] = function()
  child.lua_func(function()
    local anchor = vim.api.nvim_get_current_win()
    local bad_values = { {}, 'abc', 42, { 1, 2 }, { '⠋', false } }

    for _, bad in ipairs(bad_values) do
      local label = vim.inspect(bad)
      local wins = #vim.api.nvim_list_wins()
      local bufs = #vim.api.nvim_list_bufs()
      local ok, err = pcall(Prompt.open, anchor, prompt_opts(bad))
      -- 旧实现下 open 成功：关掉以免影响后续用例，再让断言报出失败
      if ok and err then err.close() end
      vim.cmd.stopinsert()
      assert(not ok, 'frames=' .. label .. ' 时 prompt.open 必须抛错')
      assert(tostring(err):find('vv-utils.prompt: spinner.frames', 1, true), '错误信息必须带调用方前缀并指明 frames：' .. tostring(err))
      assert(#vim.api.nvim_list_wins() == wins, 'open 失败不得残留浮窗（frames=' .. label .. '）')
      assert(#vim.api.nvim_list_bufs() == bufs, 'open 失败不得残留 buffer（frames=' .. label .. '）')
      assert(Clock._timer_count() == 0, 'open 失败不得残留时钟 timer')

      local ok_ticker, ticker_err = pcall(Loading.ticker, { frames = bad, on_frame = function() end })
      if ok_ticker and ticker_err then ticker_err:stop() end
      assert(not ok_ticker, 'frames=' .. label .. ' 时 loading.ticker 必须抛错')
      assert(tostring(ticker_err):find('vv-utils.loading: frames', 1, true), 'loading 错误信息必须指明 frames：' .. tostring(ticker_err))
      assert(Clock._timer_count() == 0, 'ticker 校验失败不得残留时钟 timer')
    end
  end)
end

T["合法缺省与自定义帧正常显示且停止"] = function()
  child.lua_func(function()
    local anchor = vim.api.nvim_get_current_win()
    -- 公共校验函数与两处入口规则一致：合法值（含缺省）不抛错
    assert(pcall(Loading.validate_frame_opts, {}), '缺省 frames / interval_ms 必须合法')
    assert(pcall(Loading.validate_frame_opts, { frames = { 'a' }, interval_ms = 1 }), '合法值不得抛错')
    assert(not pcall(Loading.validate_frame_opts, { interval_ms = 0 }), 'interval_ms = 0 必须抛错')

    -- 合法 frames：open 成功，set_busy 用的正是自定义帧
    local handle = assert(Prompt.open(anchor, prompt_opts({ 'X', 'Y' })))
    handle.set_busy(true, 'busy')
    assert(Clock._timer_count() == 1, '合法 frames 时 set_busy(true) 必须启动 spinner')
    local buf = vim.api.nvim_get_current_buf()
    local label_text = ''
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
      for _, chunk in ipairs(m[4].virt_text or {}) do label_text = label_text .. chunk[1] end
    end
    assert(label_text:find('X busy', 1, true), 'busy 文案必须带自定义帧：' .. label_text)
    handle.close()
    assert(Clock._timer_count() == 0, 'close 必须释放时钟')

    local ticker = Loading.ticker({ frames = { 'a', 'b' }, on_frame = function() end })
    assert(ticker:is_active(), '合法 frames 时 ticker 必须正常启动')
    ticker:stop()
    assert(Clock._timer_count() == 0, 'ticker stop 必须释放时钟')
  end)
end

return T
