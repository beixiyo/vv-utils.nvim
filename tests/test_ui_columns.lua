-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  source = (vim.env.VV_TEST_REPO .. '/tests/test_ui_columns.lua')
  root = vim.fn.fnamemodify(source, ':p:h:h')
  vim.opt.runtimepath:prepend(root)
  vim.o.columns, vim.o.lines = 200, 60

  Columns = require('vv-utils.ui_columns')

  function eq(actual, expected, message)
    assert(vim.deep_equal(actual, expected),
      ('%s\n期望：%s\n实际：%s'):format(message, vim.inspect(expected), vim.inspect(actual)))
  end
end)

T["文本高度与 Neovim 真实折行一致"] = function()
  child.lua_func(function()
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, false, {
      relative = 'editor', row = 0, col = 0, width = 10, height = 50, style = 'minimal',
    })
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = false

    local samples = {
      '',
      string.rep('中', 11),
      'a' .. string.rep('中', 7),
      'ab中文cd中ef文字gh',
      'hello world, 你好世界！mixed 宽窄 text',
      string.rep('x', 23),
      'é中e\204\129文',
    }
    -- width=1 捕获宽字符连同占位符跨多屏幕行时的高度低估
    for width = 1, 13 do
      vim.api.nvim_win_set_width(win, width)
      for _, text in ipairs(samples) do
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
        local real = vim.api.nvim_win_text_height(win, { start_row = 0, end_row = 0 }).all
        eq(Columns.text_height(text, width), real, ('text_height(%q, %d) 应与真实窗口一致'):format(text, width))
      end
    end
    vim.api.nvim_win_close(win, true)
    eq(Columns.text_height(string.rep('中', 11), 5), 6, '11 个「中」放 5 列宽应占 6 行')
  end)
end

T["按空格与字符边界折行保留逻辑空行"] = function()
  child.lua_func(function()
    eq(Columns.wrap('hello brave new world', 11), { 'hello brave', 'new world' }, '应在最后一个空白处断开')
    eq(Columns.wrap('aa   bbbbbb', 6), { 'aa', 'bbbbbb' }, '断点处连续空白应整体丢弃')
    eq(Columns.wrap('a supercalifragilistic b', 8), { 'a', 'supercal', 'ifragili', 'stic b' }, '超宽单词应按字符断')
    eq(Columns.wrap('hello world', 7, { break_on_space = false }), { 'hello w', 'orld' }, 'break_on_space=false 应纯按字符断')
    eq(Columns.wrap('中文字符串', 5), { '中文', '字符', '串' }, 'CJK 不应被切半')
    eq(Columns.wrap('中a', 1), { '中', 'a' }, '宽于 width 的单字符应独占一段')
    eq(Columns.wrap('first line\n\nthird', 20), { 'first line', '', 'third' }, '应按换行拆逻辑行')
    eq(Columns.wrap('', 10), { '' }, '空串应返回一个空片段')
  end)
end

T["多栏合成保留文本与高亮偏移"] = function()
  child.lua_func(function()
    local composed = Columns.compose({
      columns = {
        { sections = { 'alpha beta gamma', 'next left' } },
        { sections = { { text = '你好世界', hl = 'Special' }, '下一段' }, hl = 'String' },
      },
      width = 10,
    })
    eq(composed.lines, {
      'alpha beta │ 你好世界',
      'gamma      │ ',
      'next left  │ 下一段',
    }, 'sections 对齐：第二段两栏应从同一行开始，左栏补齐到栏宽')
    eq(composed.height, 3, 'height 应等于行数')

    local out = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(out, 0, -1, false, composed.lines)
    local function text_at(item)
      return vim.api.nvim_buf_get_text(out, item.row, item.start_col, item.row, item.end_col, {})[1]
    end
    local texts, separators = {}, 0
    for _, item in ipairs(composed.highlights) do
      if item.hl == 'FloatBorder' then
        separators = separators + 1
        eq(text_at(item), ' │ ', '分隔符高亮应精确覆盖分隔符字节')
      else
        texts[#texts + 1] = { item.row, item.hl, text_at(item) }
      end
    end
    eq(separators, 3, '每行一条分隔符高亮')
    eq(texts, {
      { 0, 'Special', '你好世界' },
      { 2, 'String', '下一段' },
    }, 'CJK 片段高亮按字节区间取回应等于原文；section hl 覆盖栏 hl，无 hl 的栏不出高亮')

    local top = Columns.compose({
      columns = { { sections = { 'alpha beta gamma', 'next' } }, { sections = { 'x', 'y' } } },
      width = 10,
      align = 'top',
      separator = '|',
    })
    eq(top.lines, { 'alpha beta|x', 'gamma     |y', 'next      |' }, "align='top' 各栏独立从顶部排")
  end)
end

T["布局决策按可用宽度与高度收益选择"] = function()
  child.lua_func(function()
    local originals, translations = {}, {}
    for index = 1, 20 do
      originals[index] = ('Paragraph %d of the original text goes on long enough to wrap twice in a narrow window.'):format(index)
      translations[index] = ('第 %d 段译文，内容足够长，在较窄的窗口里也会折成好几行显示出来。'):format(index)
    end

    local split = Columns.decide({
      columns = { originals, translations },
      available_width = 156,
      max_height = 30,
      stack_width = 80,
    })
    eq({ split.mode, split.reason, split.column_width, split.width, split.height },
      { 'split', 'split', 76, 76 * 2 + 3, split.split_height }, '宽度充足且分栏更矮时应 split')
    assert(split.split_height < split.stack_height, 'split 高度应小于 stack 高度')

    local narrow = Columns.decide({
      columns = { originals, translations },
      available_width = 76,
      max_height = 30,
      stack_width = 76,
    })
    eq({ narrow.mode, narrow.reason, narrow.column_width, narrow.width, narrow.split_height },
      { 'stack', 'narrow', 36, 76, nil }, '分栏宽度低于 min_column_width 应 narrow 并给出算出的栏宽')

    local fits = Columns.decide({
      columns = { { 'short' }, { '短' } },
      available_width = 156,
      max_height = 30,
      stack_width = 80,
    })
    eq({ fits.mode, fits.reason, fits.stack_height, fits.height }, { 'stack', 'fits', 3, 3 }, '堆叠放得下应 fits（含 1 行栏间空行）')

    -- 一栏很长、另一栏几乎为空：分栏高度由长栏决定，并不比堆叠矮
    local no_gain = Columns.decide({
      columns = { { string.rep('word ', 200) }, { 'x' } },
      available_width = 120,
      max_height = 5,
      stack_width = 120,
    })
    eq({ no_gain.mode, no_gain.reason, no_gain.height }, { 'stack', 'no_gain', no_gain.stack_height },
      '分栏不比堆叠矮时应 no_gain')
  end)
end

T["非法布局输入在边界拒绝"] = function()
  child.lua_func(function()
    local ok, err = pcall(Columns.compose, { columns = {}, width = 10 })
    assert(not ok and err:find('^vv%-utils%.ui_columns: '), '空 columns 应带前缀报错')
    ok, err = pcall(Columns.decide, { columns = { {} }, available_width = 0, max_height = 1, stack_width = 1 })
    assert(not ok and err:find('available_width'), 'available_width 非正整数应报错')
  end)
end

return T
