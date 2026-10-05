-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  root = vim.env.VV_TEST_REPO
  vim.opt.runtimepath:prepend(root)

  Loading = require('vv-utils.loading')
  Clock = require('vv-utils.loading.clock')

  ---@param buf integer
  ---@return { row: integer, col: integer, text: string, chunks: [string, string][] }[]
  function marks(buf)
    local result = {}
    -- ns_id = -1 覆盖所有 namespace（含匿名 namespace）
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
      local vt = m[4].virt_text
      if vt then
        local text = table.concat(vim.tbl_map(function(chunk) return chunk[1] end, vt))
        result[#result + 1] = { row = m[2] + 1, col = m[3], text = text, chunks = vt }
      end
    end
    return result
  end

  --- 窗口 title / footer 的全部 chunk 文本（loading 默认分段上色，内容跨多个 chunk）
  function slot_text(win, slot)
    local value = vim.api.nvim_win_get_config(win)[slot] or {}
    return table.concat(vim.tbl_map(function(chunk) return chunk[1] end, value))
  end

  function wait_ticks(n) vim.wait(80 * n + 40, function() return false end) end
end)

T["行内帧位置、高亮与宿主重写后及时重定位和隐藏"] = function()
  child.lua_func(function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'alpha', 'branch-name', 'gamma' })
    local target = 2
    local h = Loading.mark({
      buf = buf,
      get_pos = function() return { row = target, col = #'branch-name' } end,
      label = 'deleting',
    })
    local m = marks(buf)
    assert(#m == 1 and m[1].row == 2 and m[1].col == #'branch-name', '帧必须画在指定行列：' .. vim.inspect(m))
    assert(m[1].text:find('deleting', 1, true), 'label 必须拼在帧后')
    -- 分段上色：帧默认 VVLoading（蓝），label 默认 VVLoadingLabel（Comment）
    assert(m[1].chunks[1][2] == 'VVLoading' and m[1].chunks[2][1] == ' deleting' and m[1].chunks[2][2] == 'VVLoadingLabel',
      '帧与 label 必须分段、各用默认高亮组：' .. vim.inspect(m[1].chunks))
    assert(vim.api.nvim_get_hl(0, { name = 'VVLoading', link = false }).fg == 0x7aa2f7, '帧默认必须是蓝色 #7aa2f7')

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'new-top', 'alpha', 'gamma', 'branch-name' })
    target = 4
    wait_ticks(2)
    m = marks(buf)
    assert(#m == 1 and m[1].row == 4, '目标行移动后旧位置不得残留帧：' .. vim.inspect(m))

    -- 宿主整块 set_lines 重写后不等时钟 tick 立即回到正确位置（时钟间隔放大到 10s 排除 tick 干扰）
    local slow = Loading.mark({ buf = buf, get_pos = function() return { row = 1 } end, pos = 'eol', interval_ms = 10000 })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'x', 'y', 'z' })
    vim.wait(20, function() return false end)
    m = marks(buf)
    assert(#m == 1 and m[1].row == 1, '整块重写后必须立即重画回第 1 行，不能停在被挤到的位置：' .. vim.inspect(m))
    slow:stop()

    -- 自定义 hl / label_hl 分别生效；overlay 补齐空格跟随帧且不计入 label
    local colored = Loading.mark({
      buf = buf, get_pos = function() return { row = 1 } end, pos = 'overlay', width = 12,
      label = 'ab', hl = 'FrameHl', label_hl = 'LabelHl', interval_ms = 10000,
    })
    local colored_chunks = vim.tbl_filter(function(item) return item.text:find('ab', 1, true) end, marks(buf))[1].chunks
    assert(colored_chunks[1][2] == 'FrameHl' and colored_chunks[2][2] == 'LabelHl', '自定义 hl / label_hl 必须分别作用于帧与 label：' .. vim.inspect(colored_chunks))
    assert(vim.fn.strdisplaywidth(table.concat(vim.tbl_map(function(c) return c[1] end, colored_chunks))) == 12, 'width 必须按全部分段的总显示宽度补齐')
    colored:stop()

    -- 2：nil 隐藏
    target = nil
    wait_ticks(2)
    assert(#marks(buf) == 0, 'get_pos 返回 nil 必须清掉已画的帧')
    h:stop()
    h:stop()
  end)
end

T["多个实例共享时钟且退出后释放"] = function()
  child.lua_func(function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'one', 'two' })
    local h1 = Loading.mark({ buf = buf, get_pos = function() return { row = 1 } end })
    local h2 = Loading.mark({ buf = buf, get_pos = function() return { row = 2 } end })
    local h3 = Loading.ticker({ on_frame = function() end })
    assert(Clock._timer_count() == 1, '同间隔的多个实例必须共享一个 timer')
    h1:stop()
    h2:stop()
    assert(Clock._timer_count() == 1, '仍有订阅者时 timer 不得释放')
    h3:stop()
    assert(Clock._timer_count() == 0, '全部停止后 timer 必须释放')
    assert(#marks(buf) == 0, 'stop 必须清掉已画的帧')

    -- ticker 的 on_frame 返回 false 即停止（宿主资源已失效时由回调自行结束）
    local self_stopping = Loading.ticker({ on_frame = function() return false end })
    assert(not self_stopping:is_active() and Clock._timer_count() == 0, 'on_frame 返回 false 必须停止 ticker 并释放时钟')

    -- interval_ms 必须为正：0 时 libuv repeat=0 只触发一次，出两帧后停住但 handle 仍活跃
    local ok_zero = pcall(Loading.ticker, { interval_ms = 0, on_frame = function() end })
    assert(not ok_zero and Clock._timer_count() == 0, 'interval_ms = 0 必须在 API 边界断言失败且不建 timer')

    -- 5：延迟显示
    local delayed = Loading.mark({ buf = buf, get_pos = function() return { row = 1 } end, delay_ms = 200 })
    assert(#marks(buf) == 0, 'delay 期间不得显示')
    delayed:stop()
    vim.wait(300, function() return false end)
    assert(#marks(buf) == 0 and Clock._timer_count() == 0, 'delay 内 stop 后不得再显示或订阅时钟')
  end)
end

T["并发 slot 引用计数与创建失败可重试"] = function()
  child.lua_func(function()
    local buf = vim.api.nvim_create_buf(false, true)
    local created = 0
    local slot = Loading.slot(function()
      created = created + 1
      return Loading.mark({ buf = buf, get_pos = function() return { row = 1 } end })
    end)
    local release_old = slot:acquire('old')
    local release_new = slot:acquire('new')
    assert(created == 1, '并发 acquire 只能建一个显示')
    assert(marks(buf)[1].text:find('new', 1, true), '文案必须取最近一次 acquire')
    release_old()
    assert(slot:is_busy() and #marks(buf) == 1, '旧请求 release 不得停掉新请求的显示')
    release_new()
    release_new()
    assert(not slot:is_busy() and #marks(buf) == 0, '计数归零必须隐藏')

    -- create() 抛错：错误抛给调用方，且不留下永远释放不掉的登记（旧实现先入队再建，is_busy 永远 true）
    local fail_create = true
    local flaky = Loading.slot(function()
      if fail_create then error('create boom') end
      return Loading.mark({ buf = buf, get_pos = function() return { row = 1 } end })
    end)
    local ok_acq, acq_err = pcall(flaky.acquire, flaky, 'x')
    assert(not ok_acq and tostring(acq_err):find('create boom', 1, true), 'create 抛错必须透传给调用方：' .. tostring(acq_err))
    assert(not flaky:is_busy(), 'create 抛错后不得残留登记')
    fail_create = false
    local release_flaky = flaky:acquire('y')
    assert(flaky:is_busy() and #marks(buf) == 1, 'create 失败后必须能正常再次登记并显示')
    release_flaky()
    assert(not flaky:is_busy() and #marks(buf) == 0 and Clock._timer_count() == 0, '再次登记后必须能正常释放')
  end)
end

T["窗口文字恢复宿主值且资源失效自动停止"] = function()
  child.lua_func(function()
    local fbuf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(fbuf, false, {
      relative = 'editor', row = 1, col = 1, width = 30, height = 2,
      border = 'rounded', footer = { { ' Commit ^s ', 'Title' } }, footer_pos = 'center',
    })
    local wt = Loading.win_text({ win = win, slot = 'footer', label = 'Committing…' })
    local footer = vim.api.nvim_win_get_config(win).footer
    assert(footer[1][2] == 'VVLoading' and footer[2][1]:find('Committing', 1, true) and footer[2][2] == 'VVLoadingLabel',
      'win_text 默认必须分段上色写入 footer：' .. vim.inspect(footer))
    wt:stop()
    assert(vim.deep_equal(vim.api.nvim_win_get_config(win).footer, { { ' Commit ^s ', 'Title' } }), 'stop 必须原样恢复 footer（含高亮）')

    -- 原本无标题、期间未改：stop 后恢复为无标题
    local wt_nil = Loading.win_text({ win = win, slot = 'title', label = 'Loading' })
    assert(vim.api.nvim_win_get_config(win).title, 'win_text 必须写入 title')
    wt_nil:stop()
    assert(vim.api.nvim_win_get_config(win).title == nil, '原本无标题时 stop 必须恢复为无标题')

    -- 宿主在 loading 期间改了标题：stop 不得用启动时的旧值覆盖宿主的新值（旧实现无条件恢复）
    local wt_host = Loading.win_text({ win = win, slot = 'title', label = 'Loading', interval_ms = 10000 })
    vim.api.nvim_win_set_config(win, { title = { { ' Host New ', 'Title' } } })
    wt_host:stop()
    assert(vim.deep_equal(vim.api.nvim_win_get_config(win).title, { { ' Host New ', 'Title' } }),
      '宿主中途改过的标题必须保留：' .. vim.inspect(vim.api.nvim_win_get_config(win).title))
    vim.api.nvim_win_set_config(win, { title = '' })

    -- 宿主改值后 loading 又走了至少两个 tick：期间仍显示 spinner（loading 接管），stop 后必须是宿主新值
    -- （旧实现首次写入后不再读当前值：下一帧覆盖宿主值，stop 时恢复成最初的空标题）
    vim.api.nvim_win_set_config(win, { title = ' Orig ' })
    local wt_tick = Loading.win_text({ win = win, slot = 'title', label = 'Loading', interval_ms = 15 })
    vim.api.nvim_win_set_config(win, { title = { { ' Host Tick ', 'Title' } } })
    vim.wait(80, function() return false end)
    assert(slot_text(win, 'title'):find('Loading', 1, true),
      '宿主改值后 loading 继续期间必须显示 spinner：' .. vim.inspect(vim.api.nvim_win_get_config(win).title))
    wt_tick:stop()
    assert(vim.deep_equal(vim.api.nvim_win_get_config(win).title, { { ' Host Tick ', 'Title' } }),
      '宿主改值后又经过多个 tick，stop 必须恢复宿主新值：' .. vim.inspect(vim.api.nvim_win_get_config(win).title))
    vim.api.nvim_win_set_config(win, { title = '' })

    local wt2 = Loading.win_text({ win = win, slot = 'title' })
    vim.api.nvim_win_close(win, true)
    assert(not wt2:is_active(), '窗口关闭必须自动停止')

    local h4 = Loading.mark({ buf = fbuf, get_pos = function() return { row = 1 } end })
    vim.api.nvim_buf_delete(fbuf, { force = true })
    assert(not h4:is_active() and Clock._timer_count() == 0, 'buffer wipe 必须自动停止并释放时钟')
  end)
end

T["阻塞操作保留返回值与错误并始终清理"] = function()
  child.lua_func(function()
    local buf = vim.api.nvim_create_buf(false, true)
    local a, b = Loading.blocking({ mark = { buf = buf, get_pos = function() return { row = 1 } end } }, function(x)
      assert(#marks(buf) == 1, 'blocking 执行期间必须已画出静态帧')
      return x, 'second'
    end, 'first')
    assert(a == 'first' and b == 'second' and #marks(buf) == 0, 'blocking 必须透传返回值并清理')
    local ok = pcall(Loading.blocking, { mark = { buf = buf, get_pos = function() return { row = 1 } end } }, function() error('boom') end)
    assert(not ok and #marks(buf) == 0, 'fn 抛错时也必须清理并重新抛出')

    -- blocking 重抛原始错误：字符串不拼 traceback，table 错误原样抛出（旧实现 xpcall + debug.traceback）
    local _, str_err = pcall(Loading.blocking, {}, function() error('plain boom', 0) end)
    assert(str_err == 'plain boom', 'blocking 必须原样重抛字符串错误，不得拼接 traceback：' .. tostring(str_err))
    local err_obj = { code = 42 }
    local _, tbl_err = pcall(Loading.blocking, {}, function() error(err_obj) end)
    assert(tbl_err == err_obj, 'blocking 必须原样重抛 table 错误对象')

    -- interval_ms 必须是 >= 1 的整数：0.5 会被 luv 截断为 0，出两帧后停住但 is_active() 仍为 true
    local ok_half = pcall(Loading.ticker, { interval_ms = 0.5, on_frame = function() end })
    assert(not ok_half and Clock._timer_count() == 0, 'interval_ms = 0.5 必须在 API 边界断言失败且不建 timer')
  end)
end

T["延迟首次显示保留宿主标题且当前窗口编号归一化"] = function()
  child.lua_func(function()
    local dbuf = vim.api.nvim_create_buf(false, true)
    local dwin = vim.api.nvim_open_win(dbuf, false, {
      relative = 'editor', row = 1, col = 1, width = 30, height = 2, border = 'rounded', title = ' A ',
    })
    local wt_delay = Loading.win_text({ win = dwin, slot = 'title', label = 'Loading', delay_ms = 30, interval_ms = 10000 })
    vim.api.nvim_win_set_config(dwin, { title = ' B ' })
    vim.wait(200, function() return slot_text(dwin, 'title'):find('Loading', 1, true) ~= nil end)
    assert(slot_text(dwin, 'title'):find('Loading', 1, true), 'delay 到期后必须写入 title')
    wt_delay:stop()
    assert(slot_text(dwin, 'title') == ' B ',
      'delay 期间宿主改过的标题必须在 stop 后保留：' .. vim.inspect(vim.api.nvim_win_get_config(dwin).title))

    -- 从未写入（delay 内 stop）：不得动标题
    vim.api.nvim_win_set_config(dwin, { title = ' C ' })
    local wt_never = Loading.win_text({ win = dwin, slot = 'title', delay_ms = 200 })
    vim.api.nvim_win_set_config(dwin, { title = ' D ' })
    wt_never:stop()
    assert(slot_text(dwin, 'title') == ' D ', '从未写入时 stop 不得改动标题')

    -- win = 0 归一化为真实窗口编号：关闭该窗口必须自动停止（旧实现 WinClosed pattern 为 '0' 永不匹配）
    vim.api.nvim_set_current_win(dwin)
    local wt_cur = Loading.win_text({ win = 0, slot = 'title', interval_ms = 10000 })
    vim.api.nvim_win_close(dwin, true)
    assert(not wt_cur:is_active(), 'win = 0 时关闭当时的当前窗口必须自动停止')
    assert(Clock._timer_count() == 0, 'win = 0 自动停止后必须释放时钟')
  end)
end

T["当前 buffer 编号归一化不污染切换后的 buffer"] = function()
  child.lua_func(function()
    local buf_a = vim.api.nvim_create_buf(true, true)
    local buf_b = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_lines(buf_a, 0, -1, false, { 'a' })
    vim.api.nvim_buf_set_lines(buf_b, 0, -1, false, { 'b' })
    vim.api.nvim_set_current_buf(buf_a)
    local cur_mark = Loading.mark({ buf = 0, get_pos = function() return { row = 1 } end })
    vim.api.nvim_set_current_buf(buf_b)
    wait_ticks(2)
    assert(#marks(buf_b) == 0, 'buf = 0 时切换 buffer 后不得画到新的当前 buffer')
    cur_mark:stop()
    assert(#marks(buf_a) == 0 and #marks(buf_b) == 0,
      'buf = 0 stop 后两个 buffer 都不得残留 extmark：' .. vim.inspect({ a = marks(buf_a), b = marks(buf_b) }))
  end)
end

T["宿主失效后 slot 释放不重建但新请求可重建"] = function()
  child.lua_func(function()
    local wipe_buf = vim.api.nvim_create_buf(false, true)
    local wipe_created, wipe_fail = 0, false
    local wipe_slot = Loading.slot(function()
      wipe_created = wipe_created + 1
      if wipe_fail then error('create after wipe') end
      return Loading.mark({ buf = wipe_buf, get_pos = function() return { row = 1 } end })
    end)
    local rel_1 = wipe_slot:acquire('one')
    local rel_2 = wipe_slot:acquire('two')
    vim.api.nvim_buf_delete(wipe_buf, { force = true })
    wipe_fail = true
    local ok_rel, rel_err = pcall(rel_1)
    assert(ok_rel, 'handle 已失效时 release 不得因重建失败而抛错：' .. tostring(rel_err))
    assert(wipe_created == 1, 'release 递减计数时不得重建已失效的 handle')
    assert(wipe_slot:is_busy(), '仍有在途请求时 slot 必须保持 busy')
    rel_2()
    assert(not wipe_slot:is_busy() and Clock._timer_count() == 0, '全部 release 后必须空闲且释放时钟')
    -- 新的 acquire 仍会重建显示
    wipe_fail = false
    wipe_buf = vim.api.nvim_create_buf(false, true)
    local rel_3 = wipe_slot:acquire('three')
    assert(wipe_created == 2 and #marks(wipe_buf) == 1, 'handle 失效后新的 acquire 必须重建显示')
    rel_3()
  end)
end

T["匿名 namespace 不增长且多个 mark 相互独立"] = function()
  child.lua_func(function()
    Loading.mark({ buf = vim.api.nvim_create_buf(false, true), get_pos = function() return { row = 1 } end }):stop()
    local ns_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(ns_buf, 0, -1, false, { 'one', 'two' })
    local ns_before = vim.tbl_count(vim.api.nvim_get_namespaces())
    for _ = 1, 5 do
      Loading.mark({ buf = ns_buf, get_pos = function() return { row = 1 } end }):stop()
    end
    assert(vim.tbl_count(vim.api.nvim_get_namespaces()) == ns_before,
      '创建并停止多个 mark 后具名 namespace 表不得增长：' .. vim.inspect(vim.api.nvim_get_namespaces()))

    -- 并存的两个 mark 各自 stop 只清自己的 extmark
    local mark_a = Loading.mark({ buf = ns_buf, get_pos = function() return { row = 1 } end, label = 'AAA' })
    local mark_b = Loading.mark({ buf = ns_buf, get_pos = function() return { row = 2 } end, label = 'BBB' })
    assert(#marks(ns_buf) == 2, '两个 mark 必须同时显示：' .. vim.inspect(marks(ns_buf)))
    mark_a:stop()
    m = marks(ns_buf)
    assert(#m == 1 and m[1].row == 2 and m[1].text:find('BBB', 1, true), 'stop A 不得清掉 B：' .. vim.inspect(m))
    wait_ticks(2)
    m = marks(ns_buf)
    assert(#m == 1 and m[1].text:find('BBB', 1, true), 'B 继续刷新时不得清掉或重画 A：' .. vim.inspect(m))
    mark_b:stop()
    assert(#marks(ns_buf) == 0 and Clock._timer_count() == 0, '两个 mark 都 stop 后不得残留 extmark 或时钟')
  end)
end

return T
