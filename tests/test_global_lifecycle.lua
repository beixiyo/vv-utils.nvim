-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  source = (vim.env.VV_TEST_REPO .. '/tests/test_global_lifecycle.lua')
  root = vim.fn.fnamemodify(source, ':p:h:h')
  vim.opt.runtimepath:prepend(root)

  function snapshot_mapping(mode, lhs)
    local mapping = vim.fn.maparg(lhs, mode, false, true)
    return type(mapping) == 'table' and next(mapping) and mapping or nil
  end

  function restore_mapping(mode, lhs, mapping)
    pcall(vim.keymap.del, mode, lhs)
    if mapping then vim.fn.mapset(mode, false, mapping) end
  end

  Drop = require('vv-utils.drop')
  Dispatcher = require('vv-utils.drop.dispatcher')
  original_paste = vim.paste
end)

T["拖放接管、监听器释放与幂等卸载"] = function()
  child.lua_func(function()
    Drop.setup({ kitty_dnd = false })
    assert(vim.paste ~= original_paste, '拖放 setup 必须接管粘贴处理器')
    Drop.teardown()
    assert(vim.paste == original_paste, '拖放 teardown 必须恢复原粘贴处理器')

    local calls = 0
    local dispose = Drop.register(function()
      calls = calls + 1
      return true
    end)
    assert(Dispatcher.dispatch({ '/missing-drop-path' }, nil))
    dispose()
    assert(not Dispatcher.dispatch({ '/missing-drop-path' }, nil))
    assert(calls == 1, '已释放的拖放处理器不得再次执行')

    local drag_calls = 0
    local dispose_drag = Drop.on_drag(function() drag_calls = drag_calls + 1 end)
    Dispatcher.fire_drag({ kind = 'leave' })
    dispose_drag()
    Dispatcher.fire_drag({ kind = 'leave' })
    assert(drag_calls == 1, '已释放的拖拽监听器不得再次执行')
  end)
end

T["滚动禁用恢复映射、选项并取消所有动画"] = function()
  child.lua_func(function()
    local saved = {
      n_ce = snapshot_mapping('n', '<C-e>'),
      n_cy = snapshot_mapping('n', '<C-y>'),
      n_wheel = snapshot_mapping('n', '<ScrollWheelDown>'),
      mousescroll = vim.o.mousescroll,
    }

    vim.keymap.set('n', '<C-e>', '<cmd>let g:vv_scroll_original_e = 1<cr>', { desc = 'original C-e' })
    vim.keymap.set('n', '<C-y>', '<cmd>let g:vv_scroll_original_y = 1<cr>', { desc = 'original C-y' })
    vim.keymap.set('n', '<ScrollWheelDown>', '<cmd>let g:vv_scroll_original_wheel = 1<cr>', {
      desc = 'original wheel',
    })
    vim.o.mousescroll = 'ver:7,hor:3'

    local Scroll = require('vv-utils.scroll')
    local ScrollState = require('vv-utils.scroll.state')
    Scroll.setup({ mouse = 'smooth', mouse_step = 4, frame_ms = 50 })

    assert(vim.fn.maparg('<C-e>', 'n', false, true).desc == 'vv-scroll: scroll down')
    assert(vim.fn.maparg('<ScrollWheelDown>', 'n', false, true).desc == 'vv-scroll: mouse scroll down')
    assert(vim.o.mousescroll == 'ver:4,hor:6')

    local lines = {}
    for index = 1, 100 do lines[index] = 'line' end
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    Scroll.window(vim.api.nvim_get_current_win(), 20)
    assert(next(ScrollState.runtime.win_timer), '前置：滚动 fixture 必须启动动画 timer')

    Scroll.disable()
    assert(vim.fn.maparg('<C-e>', 'n', false, true).desc == 'original C-e')
    assert(vim.fn.maparg('<C-y>', 'n', false, true).desc == 'original C-y')
    assert(vim.fn.maparg('<ScrollWheelDown>', 'n', false, true).desc == 'original wheel')
    assert(vim.o.mousescroll == 'ver:7,hor:3')
    assert(not next(ScrollState.runtime.win_timer), '禁用滚动必须关闭手动滚动 timer')
    assert(not next(ScrollState.runtime.auto_timer), '禁用滚动必须关闭自动滚动 timer')

    Scroll.setup({ mouse = 'smooth', mouse_step = 4, frame_ms = 50 })
    vim.o.mousescroll = 'ver:9,hor:1'
    Scroll.disable()
    assert(vim.o.mousescroll == 'ver:9,hor:1', '禁用滚动必须保留宿主后来修改的 mousescroll')

    restore_mapping('n', '<C-e>', saved.n_ce)
    restore_mapping('n', '<C-y>', saved.n_cy)
    restore_mapping('n', '<ScrollWheelDown>', saved.n_wheel)
    vim.o.mousescroll = saved.mousescroll
  end)
end

return T
