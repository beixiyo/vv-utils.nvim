-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  this = vim.fn.fnamemodify((vim.env.VV_TEST_REPO .. '/tests/test_path_collapse_width.lua'), ':p')
  plugin_root = vim.fn.fnamemodify(this, ':h:h')

  package.path = table.concat({
    plugin_root .. '/lua/?.lua',
    plugin_root .. '/lua/?/init.lua',
    package.path,
  }, ';')

  path = require('vv-utils.path')

  function eq(name, actual, expected)
    assert(actual == expected, ('%s\n期望：%s\n实际：%s'):format(name, expected, actual))

  end
end)

T["路径宽度阶梯按 CJK 显示列与超宽兜底"] = function()
  child.lua_func(function()
    local long = 'packages/web/src/routes/admin/index.tsx'

    -- 每一级的宽度：tail3 = 33、tail2 = 26、tail1 = 20、head0 = 11
    eq('不传宽度只做第一级折叠', path.collapse_middle(long), 'packages/…/routes/admin/index.tsx')
    eq('宽度刚好容纳第一级', path.collapse_middle(long, { max_width = 33 }), 'packages/…/routes/admin/index.tsx')
    eq('少 1 列退到 tail 2', path.collapse_middle(long, { max_width = 32 }), 'packages/…/admin/index.tsx')
    eq('再窄退到 tail 1', path.collapse_middle(long, { max_width = 25 }), 'packages/…/index.tsx')
    eq('再窄去掉开头', path.collapse_middle(long, { max_width = 19 }), '…/index.tsx')
    eq('全部超宽时返回最短一级，不截断文件名', path.collapse_middle(long, { max_width = 3 }), '…/index.tsx')
    eq('层级不足且放得下时原样返回', path.collapse_middle('src/App.tsx', { max_width = 11 }), 'src/App.tsx')
    eq('层级不足但超宽时仍去掉开头', path.collapse_middle('src/App.tsx', { max_width = 10 }), '…/App.tsx')

    -- CJK 每字占 2 列：「页面/布局/首页.vue」按显示宽度而非字节或字符数判断
    local cjk = 'src/组件/页面/布局/首页.vue'
    eq('CJK 第一级显示宽度 24 时可放下', path.collapse_middle(cjk, { max_width = 24 }), 'src/…/页面/布局/首页.vue')
    eq('CJK 宽度 23 时退到 tail 2', path.collapse_middle(cjk, { max_width = 23 }), 'src/…/布局/首页.vue')
    eq('CJK 宽度 13 时去掉开头', path.collapse_middle(cjk, { max_width = 13 }), '…/首页.vue')

    eq(
      'tail 减到 1 后 head 直接降为 0',
      path.collapse_middle('a/b/c/d/e/f.lua', { head = 2, tail = 2, ellipsis = '..', max_width = 11 }),
      '../f.lua'
    )
    eq(
      'opts 覆盖起始层级与省略标记',
      path.collapse_middle('a/b/c/d/e/f.lua', { head = 2, tail = 2, ellipsis = '..', max_width = 9 }),
      '../f.lua'
    )
    eq('不传 max_width 时与原行为一致', path.collapse_middle(long, { head = 1, tail = 2 }), 'packages/…/admin/index.tsx')
    eq('head = 0 时不重复最后一级', path.collapse_middle('a/b/c/d.lua', { head = 0, tail = 1, max_width = 1 }), '…/d.lua')
  end)
end

return T
