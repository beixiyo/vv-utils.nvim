-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  this = vim.fn.fnamemodify((vim.env.VV_TEST_REPO .. '/tests/test_lsp_code_actions.lua'), ':p')
  root = vim.fn.fnamemodify(this, ':h:h')
  vim.opt.runtimepath:prepend(root)

  CodeActions = require('vv-utils.lsp.code_actions')
  Fs = require('vv-utils.fs')
  tmp = vim.fn.tempname()
  path = vim.fs.joinpath(tmp, 'fixture.tsx')
  uri = vim.uri_from_fname(path)
  original = 'rounded-[8px] p-[16px]'

  Fs.mkdir_p(tmp)
  Fs.write_all(path, original .. '\n')
  bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)
  requests = {}
  client = {
    id = 901,
    name = 'fixture-lsp',
    offset_encoding = 'utf-16',
    supports_method = function() return true end,
    request = function(_, _, params, callback)
      requests[#requests + 1] = vim.deepcopy(params)
      callback(nil, {
        {
          title = 'Fix rounded',
          kind = 'quickfix',
          edit = { changes = { [uri] = {{
            range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 13 } },
            newText = 'rounded-lg',
          }} } },
        },
        {
          title = 'Fix padding',
          kind = 'quickfix',
          edit = { changes = { [uri] = {{
            range = { start = { line = 0, character = 14 }, ['end'] = { line = 0, character = 22 } },
            newText = 'p-4',
          }} } },
        },
      })
      return true, #requests
    end,
  }

  -- vim.lsp.diagnostic 首次加载时会 Capability.enable('diagnostics') 并遍历
  -- vim.lsp.get_clients() 读取 client.attached_buffers；生产代码是懒加载它的，
  require('vim.lsp.diagnostic')

  original_get_clients = vim.lsp.get_clients
  vim.lsp.get_clients = function() return { client } end
end)

T["完整文档与当前行修复支持保存或仅修改 buffer"] = function()
  child.lua_func(function()
    local fixed = CodeActions.fix_document({ bufnr = bufnr })
    assert(fixed.changed and fixed.saved, vim.inspect(fixed))
    assert(fixed.edits_count == 2 and fixed.files_changed == 1)
    assert(Fs.read_all(path) == 'rounded-lg p-4\n')

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { original })
    vim.api.nvim_buf_call(bufnr, function() vim.cmd('silent write') end)
    requests = {}
    local line_fixed = CodeActions.fix_document({ bufnr = bufnr, line = 1, save = false })
    assert(line_fixed.changed, vim.inspect(line_fixed))
    assert(line_fixed.saved == false and vim.bo[bufnr].modified)
    assert(Fs.read_all(path) == original .. '\n', 'save=false 必须保留磁盘快照')
    assert(vim.iter(requests):all(function(params)
      return not vim.tbl_contains(params.context.only or {}, 'source.fixAll')
    end), '行级修复不得请求 source.fixAll')
  end)
end

T["响应错误携带来源与不可重试分类"] = function()
  child.lua_func(function()
    client.request = function(_, _, _, callback)
      callback({ code = -32603, message = 'fixture response failed' })
      return true, 1
    end
    local failed = CodeActions.fix_document({ bufnr = bufnr, timeout_ms = 10 })
    assert(failed.changed == false and failed.error.code == 'code_action_request_failed',
      '客户端请求失败不得误报为 no_quickfixes')
    assert(failed.error.errors['fixture-lsp'].message == 'fixture response failed')
    assert(failed.error.errors['fixture-lsp'].kind == 'response_error')
    assert(failed.error.errors['fixture-lsp'].retryable == false)
  end)
end

T["多客户端并行分派且共享超时取消"] = function()
  child.lua_func(function()
    local dispatched = {}
    local parallel_clients = {}
    for index, name in ipairs({ 'typescript-tools', 'tailwindcss' }) do
      parallel_clients[index] = {
        id = 910 + index,
        name = name,
        offset_encoding = 'utf-16',
        supports_method = function() return true end,
        request = function(self, method, _, callback)
          assert(method == 'textDocument/codeAction')
          dispatched[#dispatched + 1] = self.name
          vim.schedule(function()
            assert(#dispatched % 2 == 0, '等待响应前必须分派所有客户端请求')
            callback(nil, {})
          end)
          return true, self.id
        end,
      }
    end
    vim.lsp.get_clients = function() return parallel_clients end
    local no_fixes, no_fixes_error = CodeActions.collect_document_fixes({
      bufnr = bufnr,
      timeout_ms = 100,
    })
    assert(not no_fixes and no_fixes_error.code == 'no_quickfixes', vim.inspect(no_fixes_error))
    assert(vim.deep_equal(dispatched, {
      'typescript-tools',
      'tailwindcss',
      'typescript-tools',
      'tailwindcss',
    }), '每个请求阶段必须一起分派所有符合条件的客户端')

    local cancelled = 0
    for _, pending_client in ipairs(parallel_clients) do
      pending_client.request = function(self)
        return true, self.id
      end
      pending_client.cancel_request = function()
        cancelled = cancelled + 1
      end
    end
    -- 可控时钟让共享截止契约与机器速度无关：一轮等待只推进同一个预算。
    local real_hrtime, real_wait = vim.uv.hrtime, vim.wait
    local now, budgets = 0, {}
    vim.uv.hrtime = function() return now end
    vim.wait = function(timeout)
      budgets[#budgets + 1] = timeout
      now = now + timeout * 1000000
      return false
    end
    local timed_out, timeout_failure = CodeActions.collect_document_fixes({
      bufnr = bufnr,
      timeout_ms = 100,
    })
    vim.uv.hrtime, vim.wait = real_hrtime, real_wait
    assert(not timed_out and timeout_failure.code == 'code_action_request_failed',
      vim.inspect(timeout_failure))
    assert(timeout_failure.errors['typescript-tools'].kind == 'timeout')
    assert(timeout_failure.errors.tailwindcss.kind == 'timeout')
    assert(cancelled == 2, '共享截止到达时必须取消所有剩余请求')
    Helpers.eq(budgets, { 100 }, '两个客户端共享一次 100ms 等待预算，不得串行累加')
  end)
end

return T
