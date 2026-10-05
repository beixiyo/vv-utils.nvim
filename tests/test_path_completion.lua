-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  repo = vim.fn.fnamemodify((vim.env.VV_TEST_REPO .. '/tests/test_path_completion.lua'), ':p:h:h')
  vim.opt.runtimepath:prepend(repo)
  completion = require('vv-utils.path_completion')
  root = vim.fn.tempname()
  vim.fn.mkdir(root .. '/packages/core/src', 'p')
  vim.fn.mkdir(root .. '/src/components', 'p')
  vim.fn.mkdir(root .. '/fixtures/space-dir', 'p')
  vim.fn.mkdir(root .. '/cwd-only', 'p')
  vim.fn.mkdir(root .. '/.hidden-dir', 'p')
  vim.fn.writefile({ 'x' }, root .. '/packages/core/index.ts')
  vim.fn.writefile({ 'x' }, root .. '/fixtures/file,name.txt')
  vim.fn.writefile({ 'x' }, root .. '/cwd-file.txt')
  function item(result, word)
    for _, candidate in ipairs(result.items) do
      if candidate.word == word then return candidate end
    end
    error('missing candidate ' .. word .. ': ' .. vim.inspect(result.items))
  end
end)

T["只替换光标所在的顶层逗号分段"] = function()
  child.lua_func(function()
    local input = '*.{ts,tsx}, ./pack'
      local result = completion.glob(input, { cwd = root })
      assert(result.start_col == #'*.{ts,tsx}, ', result.start_col)
      assert(item(result, './packages/').kind == 'Folder')
  end)
end

T["保留排除前缀和嵌套目录"] = function()
  child.lua_func(function()
    local result = completion.glob('!src/co', { cwd = root })
      assert(result.start_col == 0)
      assert(item(result, '!src/components/').kind == 'Folder')
  end)
end

T["保留 ./ 和含空格目录"] = function()
  child.lua_func(function()
    local result = completion.glob('./fixtures/sp', { cwd = root })
      assert(item(result, './fixtures/space-dir/').abbr == 'space-dir/')
  end)
end

T["未锚定片段可补全任意深度的路径"] = function()
  child.lua_func(function()
    assert(vim.fn.executable('fd') == 1, '此测试需要 fd，不能静默跳过递归补全覆盖')

      local result = completion.glob('core', { cwd = root })
      assert(item(result, 'packages/core/').kind == 'Folder')
      assert(item(completion.glob('CORE', { cwd = root }), 'packages/core/'))
      assert(item(completion.glob('core/sr', { cwd = root }), 'packages/core/src/'))
  end)
end

T["./ 前缀始终锚定 cwd"] = function()
  child.lua_func(function()
    assert(vim.fn.executable('fd') == 1, '此测试需要 fd，不能静默跳过递归补全覆盖')

      assert(#completion.glob('./core', { cwd = root }).items == 0)
      assert(item(completion.glob('./pack', { cwd = root }), './packages/'))
  end)
end

T["转义文件名中的顶层逗号"] = function()
  child.lua_func(function()
    local result = completion.glob('./fixtures/file', { cwd = root })
      assert(item(result, './fixtures/file\\,name.txt').kind == 'File')
  end)
end

T["光标位于输入中间时只读取光标前缀"] = function()
  child.lua_func(function()
    local input = './src/co-tail'
      local result = completion.glob(input, { cwd = root, cursor = #'./src/co' })
      assert(result.start_col == 0)
      assert(item(result, './src/components/'))
  end)
end

T["已有索引补全复用 glob 分段、锚定与目录类型"] = function()
  child.lua_func(function()
    local paths = {
        'packages/',
        'packages/core/',
        'packages/core/src/',
        'src/',
        'src/components/',
        'file,name.txt',
      }
      local directories = {
        ['packages/'] = true,
        ['packages/core/'] = true,
        ['packages/core/src/'] = true,
        ['src/'] = true,
        ['src/components/'] = true,
      }
      local opts = {
        max_items = 10,
        is_directory = function(path) return directories[path] == true end,
      }

      assert(item(completion.glob_from_paths('core/sr', paths, opts), 'packages/core/src/').kind == 'Folder')
      assert(item(completion.glob_from_paths('./sr', paths, opts), './src/'))
      assert(#completion.glob_from_paths('./core', paths, opts).items == 0)

      local segmented = completion.glob_from_paths('*.lua, !file', paths, opts)
      assert(segmented.start_col == #'*.lua, ')
      assert(item(segmented, '!file\\,name.txt').kind == 'File')
      assert(#completion.glob_from_paths('src/*', paths, opts).items == 0)
  end)
end

T["Cwd 补全只返回目录"] = function()
  child.lua_func(function()
    local result = completion.directory('cwd-', { cwd = root })
      assert(item(result, 'cwd-only/').kind == 'Folder')
      for _, candidate in ipairs(result.items) do
        assert(candidate.kind == 'Folder', vim.inspect(candidate))
      end
  end)
end

T["空前缀不主动列出隐藏路径"] = function()
  child.lua_func(function()
    local result = completion.glob('', { cwd = root })
      for _, candidate in ipairs(result.items) do
        assert(candidate.word ~= '.hidden-dir/')
      end
      assert(item(completion.glob('.h', { cwd = root }), '.hidden-dir/'))
  end)
end

T["通配符之后不提供错误的文件系统候选"] = function()
  child.lua_func(function()
    local result = completion.glob('src/*/co', { cwd = root })
      assert(#result.items == 0)
  end)
end

T["无效 cwd 安静返回空候选"] = function()
  child.lua_func(function()
    local result = completion.glob('core', { cwd = root .. '/missing' })
      assert(#result.items == 0)
  end)
end

T["最终候选数量可独立配置"] = function()
  child.lua_func(function()
    vim.fn.mkdir(root .. '/many', 'p')
      for index = 1, 8 do
        vim.fn.writefile({ 'x' }, string.format('%s/many/item-%02d.txt', root, index))
      end

      local result = completion.glob('./many/item', {
        cwd = root,
        max_items = 3,
        scan_max_items = 20,
      })
      assert(#result.items == 3, #result.items)
  end)
end

T["fd 在扫描预算前应用 basename 和 parent 约束"] = function()
  child.lua_func(function()
    assert(vim.fn.executable('fd') == 1, '此测试需要 fd，不能静默跳过扫描预算覆盖')

      for index = 1, 80 do
        local directory = string.format('%s/noise-%02d', root, index)
        vim.fn.mkdir(directory, 'p')
        vim.fn.writefile({ 'x' }, directory .. '/xfoo-target.txt')
      end
      vim.fn.mkdir(root .. '/deep/one', 'p')
      vim.fn.writefile({ 'x' }, root .. '/deep/one/foo-target.txt')

      local result = completion.glob('one/foo-target', {
        cwd = root,
        max_items = 10,
        scan_max_items = 1,
      })
      assert(item(result, 'deep/one/foo-target.txt'))
  end)
end

T["异步路径补全返回可取消请求并产生相同候选"] = function()
  child.lua_func(function()
    local result
      local cancel = completion.glob_async('core', {
        cwd = root,
        max_items = 10,
        scan_max_items = 20,
      }, function(value) result = value end)

      assert(type(cancel) == 'function')
      assert(result == nil, '异步补全不得同步阻塞等待结果')
      assert(vim.wait(1000, function() return result ~= nil end), '等待异步补全超时')
      assert(item(result, 'packages/core/'))
  end)
end

return T
