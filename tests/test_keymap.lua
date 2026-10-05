-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  root = vim.fn.fnamemodify((vim.env.VV_TEST_REPO .. '/tests/test_keymap.lua'), ':h:h')
  package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. package.path
  Keymap = require('vv-utils.keymap')
  function map_desc(buf)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
      if map.lhs == 'gf' then return map.desc end
    end
  end
  function map_desc_by_lhs(buf, lhs)
    local target = vim.fn.keytrans(vim.keycode(lhs))
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
      if vim.fn.keytrans(vim.keycode(map.lhs)) == target then return map.desc end
    end
  end
  function set_filetype(buf, filetype)
    vim.api.nvim_buf_call(buf, function()
      vim.cmd('set filetype=' .. filetype)
    end)
  end
end)

T["filetype 进入、离开与重进会正确接管和恢复映射"] = function()
  child.lua_func(function()
    local buf = vim.api.nvim_create_buf(false, true)
      vim.keymap.set('n', 'gf', '<cmd>let b:original_gf = 1<cr>', { buffer = buf, desc = 'original gf' })
      local handle = Keymap.attach({
        id = 'test.keymap.lifecycle',
        filetypes = { 'markdown' },
        mappings = { { mode = 'n', lhs = 'gf', rhs = function() end, opts = { desc = 'owned gf' } } },
      })

      set_filetype(buf, 'markdown')
      assert(map_desc(buf) == 'owned gf')
      set_filetype(buf, 'text')
      assert(map_desc(buf) == 'original gf')
      set_filetype(buf, 'markdown')
      assert(map_desc(buf) == 'owned gf')
      handle:detach()
      assert(map_desc(buf) == 'original gf')
      vim.api.nvim_buf_delete(buf, { force = true })
  end)
end

T["外部重绑优先于之后的自动解绑"] = function()
  child.lua_func(function()
    local buf = vim.api.nvim_create_buf(false, true)
      local handle = Keymap.attach({
        id = 'test.keymap.external',
        filetypes = { 'markdown' },
        mappings = { { mode = 'n', lhs = 'gf', rhs = function() end, opts = { desc = 'owned gf' } } },
      })

      set_filetype(buf, 'markdown')
      vim.keymap.set('n', 'gf', '<cmd>let b:external_gf = 1<cr>', { buffer = buf, desc = 'external gf' })
      set_filetype(buf, 'text')
      assert(map_desc(buf) == 'external gf')
      handle:detach()
      vim.api.nvim_buf_delete(buf, { force = true })
  end)
end

T["控制键标准化后仍会在 detach 时归还映射"] = function()
  child.lua_func(function()
    local buf = vim.api.nvim_create_buf(false, true)
      local handle = Keymap.attach({
        id = 'test.keymap.control-key',
        when = function(context) return context.buf == buf end,
        mappings = { { mode = 'n', lhs = '<C-e>', rhs = function() end, opts = { desc = 'owned C-e' } } },
      })

      assert(map_desc_by_lhs(buf, '<C-e>') == 'owned C-e')
      handle:detach()
      assert(map_desc_by_lhs(buf, '<C-e>') == nil)
      vim.api.nvim_buf_delete(buf, { force = true })
  end)
end

return T
