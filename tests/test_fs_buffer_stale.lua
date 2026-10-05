-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  this = vim.fn.fnamemodify((vim.env.VV_TEST_REPO .. '/tests/test_fs_buffer_stale.lua'), ':p')
  plugin_root = vim.fn.fnamemodify(this, ':h:h')

  package.path = table.concat({
    plugin_root .. '/lua/?.lua',
    plugin_root .. '/lua/?/init.lua',
    package.path,
  }, ';')

  vim.cmd('filetype plugin on')

  Fs = require('vv-utils.fs')

  root = vim.fn.tempname()
  vim.fn.mkdir(root, 'p')
  root = assert(vim.uv.fs_realpath(root))

  events = {}
  vim.lsp.config('vv_fake_stale', {
    cmd = function()
      local id = 0
      return {
        request = function(method, _, callback)
          if method == 'initialize' then
            callback(nil, { capabilities = { textDocumentSync = { openClose = true, change = 2 } } })
          elseif method == 'shutdown' then
            callback(nil, nil)
          end
          id = id + 1
          return true, id
        end,
        notify = function(method, params)
          local td = params and params.textDocument
          events[#events + 1] = { method = method, uri = td and td.uri }
          return true
        end,
        is_closing = function() return false end,
        terminate = function() end,
      }
    end,
    filetypes = { 'lua' },
  })
  vim.lsp.enable('vv_fake_stale')

  function open(path)
    vim.fn.mkdir(vim.fs.dirname(path), 'p')
    vim.fn.writefile({ 'return 1' }, path)
    vim.cmd('silent edit ' .. vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()
    assert(vim.wait(2000, function() return #vim.lsp.get_clients({ bufnr = buf }) == 1 end), '前置：LSP 应附着 ' .. path)
    return buf
  end

  function closed_uris()
    local out = {}
    for _, e in ipairs(events) do
      if e.method == 'textDocument/didClose' then out[e.uri] = true end
    end
    return out
  end
end)

T["只关闭过期未修改文件且保持布局与 LSP 通知"] = function()
  child.lua_func(function()
    local dir = root .. '/pkg'
    local stale = open(dir .. '/stale.lua')
    local dirty = open(dir .. '/dirty.lua')
    vim.api.nvim_buf_set_lines(dirty, 0, -1, false, { 'return 2' })
    local alive = open(dir .. '/alive.lua')
    local sibling = open(root .. '/pkg2/stale.lua')
    local shown = open(dir .. '/sub/shown.lua')

    -- shown 显示在一个分屏里，另一个窗口显示 alive
    vim.cmd('vsplit')
    local shown_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(shown_win, shown)
    local other_win = vim.fn.win_getid(vim.fn.winnr('l'))
    vim.api.nvim_win_set_buf(other_win, alive)
    local wins_before = #vim.api.nvim_tabpage_list_wins(0)

    for _, path in ipairs({ dir .. '/stale.lua', dir .. '/dirty.lua', root .. '/pkg2/stale.lua', dir .. '/sub/shown.lua' }) do
      assert(os.remove(path))
    end

    events = {}
    local closed = Fs.close_stale_buffers(dir)
    vim.wait(200)

    table.sort(closed)
    local expected = { stale, shown }
    table.sort(expected)
    assert(vim.deep_equal(closed, expected), '应恰好关闭 stale 与 shown，实际 ' .. vim.inspect(closed))
    assert(not vim.api.nvim_buf_is_valid(stale), '过期且未修改的 buffer 应被关闭')
    assert(not vim.api.nvim_buf_is_valid(shown), '显示在窗口里的过期 buffer 也应被关闭')

    assert(vim.api.nvim_buf_is_loaded(dirty), '已修改的 buffer 绝不能关闭，即使磁盘文件已不存在')
    assert(vim.api.nvim_buf_get_lines(dirty, 0, -1, false)[1] == 'return 2', '已修改 buffer 的内容必须原样保留')
    assert(vim.api.nvim_buf_is_loaded(alive), '磁盘上仍存在的文件 buffer 不能关闭')
    assert(vim.api.nvim_buf_is_loaded(sibling), '同前缀兄弟目录 pkg2 下的 buffer 不在范围内，不能关闭')

    local uris = closed_uris()
    assert(uris[vim.uri_from_fname(dir .. '/stale.lua')], '服务端应收到 stale 的 didClose')
    assert(uris[vim.uri_from_fname(dir .. '/sub/shown.lua')], '服务端应收到 shown 的 didClose')
    assert(not uris[vim.uri_from_fname(dir .. '/dirty.lua')], '已修改 buffer 不应收到 didClose')

    assert(#vim.api.nvim_tabpage_list_wins(0) == wins_before, '关闭过期 buffer 不应关闭窗口')
    assert(vim.api.nvim_win_is_valid(shown_win), '原本显示过期 buffer 的窗口应保留')
  end)
end

T["固定 buffer 的窗口保留过期 buffer"] = function()
  child.lua_func(function()
    -- winfixbuf 的窗口换不掉 buffer：不能抛错打断调用方，也不能连窗口一起关掉，该 buffer 保留
    local fixed = open(root .. '/fixed.lua')
    local fixed_win = vim.api.nvim_get_current_win()
    vim.wo[fixed_win].winfixbuf = true
    assert(os.remove(root .. '/fixed.lua'))
    local ok_fixed, closed_fixed = pcall(Fs.close_stale_buffers, root .. '/fixed.lua')
    assert(ok_fixed, 'winfixbuf 窗口里的过期 buffer 不能让 close_stale_buffers 抛错：' .. tostring(closed_fixed))
    assert(#closed_fixed == 0 and vim.api.nvim_buf_is_valid(fixed), '换不掉窗口的 buffer 应保留')
    assert(vim.api.nvim_win_is_valid(fixed_win) and vim.api.nvim_win_get_buf(fixed_win) == fixed, 'winfixbuf 窗口不能被关闭或换 buffer')
    vim.wo[fixed_win].winfixbuf = false
  end)
end

T["切换窗口时被用户修改的 buffer 不可删除"] = function()
  child.lua_func(function()
    -- 换窗口时 BufLeave 改了它：变成已修改，绝不能被强制丢弃
    local changing = open(root .. '/changing.lua')
    assert(os.remove(root .. '/changing.lua'))
    vim.api.nvim_create_autocmd('BufLeave', {
      buffer = changing,
      once = true,
      callback = function() vim.api.nvim_buf_set_lines(changing, 0, -1, false, { 'changed on leave' }) end,
    })
    Fs.close_stale_buffers(root .. '/changing.lua')
    assert(vim.api.nvim_buf_is_valid(changing) and vim.api.nvim_buf_get_lines(changing, 0, -1, false)[1] == 'changed on leave',
      '换窗口期间被改动的 buffer 不能被强制丢弃')
    vim.bo[changing].modified = false
  end)
end

T["单文件路径关闭与无匹配返回空表"] = function()
  child.lua_func(function()
    -- 单个文件路径同样可用；未命中时返回空表
    local single = open(root .. '/single.lua')
    assert(os.remove(root .. '/single.lua'))
    assert(#Fs.close_stale_buffers(root .. '/nothing-here.lua') == 0, '未命中时不应关闭任何 buffer')
    assert(vim.deep_equal(Fs.close_stale_buffers(root .. '/single.lua'), { single }), '文件路径应关闭对应 buffer')

    vim.lsp.enable('vv_fake_stale', false)
  end)
end

return T
