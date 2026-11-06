-- 真实公开入口验证 linebreak 默认副本；同 buffer 的原生局部复制不算泄漏。
local T, child = dofile('tests/helpers.lua').new_set()

local function check_options(mode, baseline)
  child.lua_func(function(mode, baseline)
    local api = vim.api
    local Modal = require('vv-utils.modal')
    vim.o.columns, vim.o.lines = 100, 35
    local origin, original_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
    local original_lines = { '用户正文保持原样 alpha beta gamma' }
    api.nvim_buf_set_lines(original_buf, 0, -1, false, original_lines)
    vim.bo[original_buf].modified = false
    api.nvim_set_option_value('linebreak', baseline, { win = origin })
    api.nvim_set_option_value('wrap', true, { win = origin })
    local function expect(win, scope, value, message)
      Helpers.eq(api.nvim_get_option_value('linebreak', { win = win, scope = scope }), value, message)
    end
    local function unchanged()
      expect(origin, 'local', baseline, '原用户窗口局部 linebreak 不得改变')
      expect(origin, 'global', baseline, '原用户窗口默认副本不得改变')
      Helpers.eq(api.nvim_buf_get_lines(original_buf, 0, -1, false), original_lines, '用户正文不得修改')
      assert(not vim.bo[original_buf].modified, '用户正文不得标为已修改')
    end
    local body = 'aaaaaaa bbbbbbb ccccccc ddddddd eeeeeee fffffff ggggggg'
    local function open()
      local handle = Modal.open({
        title = 'Options', body = { body },
        actions = { { id = 'ok', label = 'OK', keys = 'o' } },
        window = { min_width = 20, max_width = 20 },
      })
      local win = api.nvim_get_current_win()
      local buf = api.nvim_win_get_buf(win)
      assert(handle.is_open() and win ~= origin, '公开入口必须聚焦新 modal 浮窗')
      expect(win, 'local', true, 'modal 必须保留局部单词折行')
      assert(api.nvim_get_option_value('wrap', { win = win }), 'modal 必须继续启用折行')
      assert(api.nvim_win_get_config(win).relative == 'editor' and api.nvim_win_get_width(win) == 20,
        'modal 必须保留指定宽度与浮窗布局')
      local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
      assert(lines[1] == '  ' .. body, '软折行不得拆分正文物理行')
      local word_height = api.nvim_win_text_height(win, { start_row = 0, end_row = 0 }).all
      assert(word_height > math.ceil(#lines[1] / 20), '长正文必须按单词而非按字符折行')
      assert(not vim.bo[buf].modifiable and not vim.bo[buf].modified, 'modal 正文必须保持只读且未修改')
      unchanged()
      return handle, win, buf, lines
    end
    local function fresh()
      local buf = api.nvim_create_buf(true, false)
      api.nvim_buf_set_lines(buf, 0, -1, false, { body })
      vim.bo[buf].modified = false
      return buf
    end
    local handle, win, buf, lines = open()
    if mode == '新缓冲浮窗' then
      local derived = api.nvim_open_win(fresh(), false, {
        relative = 'editor', row = 1, col = 1, width = 20, height = 5,
      })
      expect(derived, 'local', baseline, '派生普通浮窗必须使用用户 linebreak 默认值')
      expect(derived, 'global', baseline, '派生普通浮窗不得继承 modal 默认副本污染')
      api.nvim_win_close(derived, true)
    elseif mode == '同缓冲分屏后换普通缓冲' then
      vim.cmd('vsplit')
      local derived = api.nvim_get_current_win()
      expect(derived, 'local', true, '同 buffer 分屏仍应正常复制局部单词折行')
      local ordinary = fresh()
      api.nvim_win_set_buf(derived, ordinary)
      expect(derived, 'local', baseline, '分屏切普通 buffer 必须回到用户默认值')
      expect(derived, 'global', baseline, '普通分屏的默认副本不得污染')
      Helpers.eq(api.nvim_buf_get_lines(ordinary, 0, -1, false), { body }, '普通 buffer 内容不得改变')
      assert(not vim.bo[ordinary].modified, '普通 buffer 不得标为已修改')
      api.nvim_win_close(derived, true)
      api.nvim_set_current_win(win)
    elseif mode == '同窗换普通缓冲' then
      api.nvim_win_set_buf(win, fresh())
      expect(win, 'local', baseline, '同窗换普通 buffer 必须回到用户默认值')
      expect(win, 'global', baseline, '同窗换普通 buffer 不得保留 modal 默认副本污染')
      assert(not handle.is_open() and not api.nvim_buf_is_valid(buf), '替换触发 wipe 后 handle 必须关闭')
    else
      expect(win, 'global', baseline, 'modal 打开不得改写 linebreak 默认副本')
    end
    if api.nvim_buf_is_valid(buf) then
      Helpers.eq(api.nvim_buf_get_lines(buf, 0, -1, false), lines, '派生窗口不得改变 modal 正文')
      assert(not vim.bo[buf].modified, '派生窗口不得修改 modal 内容')
    end
    handle.close()
    handle.close()
    assert(not handle.is_open(), '关闭必须幂等且不再报告已打开')
    -- 换 buffer 会先结束 handle；留下的普通浮窗由本测试创建路径负责清理。
    if api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
    assert(api.nvim_get_current_win() == origin, '关闭后必须回到原用户窗口')
    unchanged()
    local reopened, reopened_win = open()
    expect(reopened_win, 'global', baseline, '重开不得改写默认副本或强制清 false')
    reopened.close()
    assert(not reopened.is_open() and not api.nvim_win_is_valid(reopened_win), '重开的 modal 必须正常关闭')
    unchanged()
  end, mode, baseline)
end

for _, baseline in ipairs({ false, true }) do
  for _, mode in ipairs({ '关闭重开', '新缓冲浮窗', '同缓冲分屏后换普通缓冲', '同窗换普通缓冲' }) do
    T[('初始 linebreak=%s：%s'):format(tostring(baseline), mode)] = function()
      check_options(mode, baseline)
    end
  end
end

return T
