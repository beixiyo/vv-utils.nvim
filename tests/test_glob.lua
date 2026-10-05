-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  this = vim.fn.fnamemodify((vim.env.VV_TEST_REPO .. '/tests/test_glob.lua'), ':p')
  plugin_root = vim.fn.fnamemodify(this, ':h:h')

  package.path = table.concat({
    plugin_root .. '/lua/?.lua',
    plugin_root .. '/lua/?/init.lua',
    package.path,
  }, ';')

  glob = require('vv-utils.glob')
end)

T["搜索简写展开、转义分段、排除与顺序保持"] = function()
  child.lua_func(function()
    local function assert_list(name, actual, expected) Helpers.eq(actual, expected, name) end
    local split = assert(glob.split('*.{ts,tsx}, **/*.test.ts, **/[a,b].txt, file\\,name.txt, path with spaces/**'))
    assert_list('brace / 字符类 / 转义逗号 / 空格路径不被误拆', split, {
      '*.{ts,tsx}',
      '**/*.test.ts',
      '**/[a,b].txt',
      'file\\,name.txt',
      'path with spaces/**',
    })

    assert_list('普通路径在任意深度同时匹配本体和后代', assert(glob.compile_rg('core/src')), {
      '**/core/src/**',
      '**/core/src',
    })

    assert_list('./ 路径锚定搜索根', assert(glob.compile_rg('./packages/core/src/')), {
      '/packages/core/src/**',
      '/packages/core/src',
    })

    assert_list('Windows 分隔符规范化后保持 ./ 语义', assert(glob.compile_rg([[.\packages\core\src\]])), {
      '/packages/core/src/**',
      '/packages/core/src',
    })

    assert_list('无扩展名输入不猜测文件或目录', assert(glob.compile_rg('LICENSE')), {
      '**/LICENSE/**',
      '**/LICENSE',
    })

    assert_list('扩展名简写对齐 VS Code', assert(glob.compile_rg('.js')), {
      '**/*.js/**',
      '**/*.js',
    })

    assert_list('显式 globstar 不重复扩展', assert(glob.compile_rg('**/*.ts')), {
      '**/*.ts/**',
      '**/*.ts',
    })

    assert_list('! 前缀同时排除本体和后代', assert(glob.compile_rg('!test')), {
      '!**/test/**',
      '!**/test',
    })

    assert_list('调用方可强制生成排除 pattern', assert(glob.compile_rg('test', { negate = true })), {
      '!**/test/**',
      '!**/test',
    })

    local compiled = assert(glob.compile_rg_list('*.{ts,tsx}, ./packages/core/src/', { negate = true }))
    assert_list('列表编译保持条目和展开顺序', compiled, {
      '!**/*.{ts,tsx}/**',
      '!**/*.{ts,tsx}',
      '!/packages/core/src/**',
      '!/packages/core/src',
    })

    local generic = assert(glob.compile_list('core/src, !./vendor'))
    assert(vim.deep_equal(generic, {
      {
        patterns = { '**/core/src/**', '**/core/src' },
        negated = false,
      },
      {
        patterns = { '/vendor/**', '/vendor' },
        negated = true,
      },
    }), vim.inspect(generic))

  end)
end

T["非法 glob 结构与越出搜索根的路径被拒绝"] = function()
  child.lua_func(function()
    local _, brace_error = glob.split('*.{ts,tsx')
    assert(brace_error == 'unclosed { in glob pattern', brace_error)

    local _, class_error = glob.split('**/[ab')
    assert(class_error == 'unclosed [ in glob pattern', class_error)

    local _, parent_error = glob.compile_rg('../shared')
    assert(parent_error and parent_error:find('change Cwd', 1, true), parent_error)

    local _, absolute_error = glob.compile_rg('/private/tmp/project')
    assert(absolute_error and absolute_error:find('change Cwd', 1, true), absolute_error)
  end)
end

return T
