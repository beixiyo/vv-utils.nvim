-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  this = vim.fn.fnamemodify((vim.env.VV_TEST_REPO .. '/tests/test_lsp_fix.lua'), ':p')
  root = vim.fn.fnamemodify(this, ':h:h')
  vim.opt.runtimepath:prepend(root)
  vim.cmd('filetype on')

  Fix = require('vv-utils.lsp.fix')
  Fs = require('vv-utils.fs')
  tmp = vim.fn.tempname()
  path = vim.fs.joinpath(tmp, 'fixture.tsx')
  uri = vim.uri_from_fname(path)
  Fs.mkdir_p(tmp)
  Fs.write_all(path, 'rounded-[8px] p-[16px]\n')
  requests = 0
  client = {
    id = 902,
    name = 'fixture-lsp',
    initialized = true,
    config = { filetypes = { 'typescriptreact' }, cmd = { vim.v.progpath } },
    offset_encoding = 'utf-16',
    supports_method = function() return true end,
    request = function(_, _, _, callback)
      requests = requests + 1
      local actions = {{
        title = 'Fix rounded',
        kind = 'quickfix',
        edit = { changes = { [uri] = {{
          range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 13 } },
          newText = 'rounded-lg',
        }} } },
      }}
      if requests >= 2 then
        actions[#actions + 1] = {
          title = 'Fix padding',
          kind = 'quickfix',
          edit = { changes = { [uri] = {{
            range = { start = { line = 0, character = 14 }, ['end'] = { line = 0, character = 22 } },
            newText = 'p-4',
          }} } },
        }
      end
      callback(nil, actions)
      return true, requests
    end,
  }

  original_get_clients = vim.lsp.get_clients
  original_get_configs = vim.lsp.get_configs
  vim.lsp.get_configs = function() return { client.config } end
  vim.lsp.get_clients = function(filter)
    if filter and filter.method and filter.method ~= 'textDocument/codeAction' then return {} end
    return { client }
  end
end)

T["内容探测识别无扩展名脚本且排除二进制"] = function()
  child.lua_func(function()
    local script_path = vim.fs.joinpath(tmp, 'script')
    Fs.write_all(script_path, '#!/usr/bin/env bash\necho ok\n')
    assert(Fix.detect_filetype(script_path) == 'sh', '内容检测必须支持无扩展名脚本')
    local binary_path = vim.fs.joinpath(tmp, 'binary')
    Fs.write_all(binary_path, 'PNG\0binary')
    assert(Fix.detect_filetype(binary_path) == nil, '二进制文件必须跳过内容文件类型检测')
  end)
end

T["临时修复 buffer 保存结果后销毁"] = function()
  child.lua_func(function()
    local result = Fix.file({ path = path, timeout_ms = 2000 })
    assert(result.changed and result.edits_count == 2, vim.inspect(result))
    assert(Fs.read_all(path) == 'rounded-lg p-4\n')
    assert(vim.fn.bufnr(path) == -1, '临时修复 buffer 必须被删除')
  end)
end

T["暂时超时重试成功且永久失败不写磁盘"] = function()
  child.lua_func(function()
    Fs.write_all(path, 'rounded-[8px] p-[16px]\n')
    local transient_requests = 0
    client.request = function(_, _, _, callback)
      transient_requests = transient_requests + 1
      if transient_requests == 1 then return true, transient_requests end
      callback(nil, {{
        title = 'Fix all after retry',
        kind = 'quickfix',
        edit = { changes = { [uri] = {
          {
            range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 13 } },
            newText = 'rounded-lg',
          },
          {
            range = { start = { line = 0, character = 14 }, ['end'] = { line = 0, character = 22 } },
            newText = 'p-4',
          },
        } } },
      }})
      return true, transient_requests
    end
    local retried = Fix.file({ path = path, timeout_ms = 2000 })
    assert(retried.changed and transient_requests >= 3, '暂时超时必须重试直到成功')

    Fs.write_all(path, 'rounded-[8px] p-[16px]\n')
    client.request = function()
      return true, 1
    end
    local failed = Fix.file({ path = path, timeout_ms = 1000 })
    assert(failed.error.code == 'code_action_request_failed', vim.inspect(failed))
    assert(Fs.read_all(path) == 'rounded-[8px] p-[16px]\n', '收集失败不得修改磁盘')
  end)
end

T["缺失 LSP 配置或程序快速失败且函数 transport 被接受"] = function()
  child.lua_func(function()
    vim.lsp.get_clients = function() return {} end
    local no_config, no_config_error = Fix.check_path_support(path, {})
    assert(not no_config and no_config_error.code == 'no_lsp_config', vim.inspect(no_config_error))

    local unavailable = 'vv-utils-language-server-that-does-not-exist'
    local executable, executable_error = Fix.check_path_support(path, {{
      filetypes = { 'typescriptreact' },
      cmd = { unavailable, '--stdio' },
    }})
    assert(not executable and executable_error.code == 'lsp_executable_missing',
      vim.inspect(executable_error))
    assert(vim.deep_equal(executable_error.executables, { unavailable }))

    local original_wait = vim.wait
    local attachment_waits = 0
    vim.wait = function(...)
      attachment_waits = attachment_waits + 1
      return original_wait(...)
    end
    local missing_result = Fix.file({
      path = path,
      configs = {{
        filetypes = { 'typescriptreact' },
        cmd = { unavailable, '--stdio' },
      }},
      timeout_ms = 1000,
    })
    vim.wait = original_wait
    assert(missing_result.error.code == 'lsp_executable_missing', vim.inspect(missing_result))
    assert(attachment_waits == 0, '缺少 LSP 程序必须在等待附着前立即返回')
    assert(vim.fn.bufnr(path) == -1, '不可用 LSP 不得创建临时 buffer')

    local custom_transport = Fix.check_path_support(path, {{
      filetypes = { 'typescriptreact' },
      cmd = function() end,
    }})
    assert(custom_transport, '函数 transport 不得被静态程序预检拒绝')

    local mixed_configs = Fix.check_path_support(path, {
      {
        filetypes = { 'typescriptreact' },
        cmd = { unavailable },
      },
      {
        filetypes = { 'typescriptreact' },
        cmd = { vim.v.progpath, '--headless' },
      },
    })
    assert(mixed_configs, '一个可用的匹配配置即可支持该路径')
  end)
end

return T
