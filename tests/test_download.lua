-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  root = vim.env.VV_TEST_REPO
  vim.opt.runtimepath:prepend(root)

  Download = require('vv-utils.download')
  original_executable = vim.fn.executable
  original_system = vim.system

  function with_executables(available, callback)
    vim.fn.executable = function(command)
      return available[command] and 1 or 0
    end
    local ok, error = pcall(callback)
    vim.fn.executable = original_executable
    if not ok then error(error) end
  end
end)

T["按平台与可执行程序选择下载器"] = function()
  child.lua_func(function()
    with_executables({ curl = true, wget = true }, function()
      local resolved = assert(Download.resolve({ sysname = 'Darwin' }))
      assert(resolved.name == 'curl' and resolved.command == 'curl')
    end)

    with_executables({ wget = true }, function()
      local resolved = assert(Download.resolve({ sysname = 'Linux' }))
      assert(resolved.name == 'wget' and resolved.command == 'wget')
    end)

    with_executables({ ['powershell.exe'] = true, ['curl.exe'] = true, curl = true }, function()
      local resolved = assert(Download.resolve({ sysname = 'Windows_NT' }))
      assert(resolved.name == 'PowerShell' and resolved.command == 'powershell.exe')
    end)

    with_executables({ ['curl.exe'] = true, curl = true }, function()
      local resolved = assert(Download.resolve({ sysname = 'Windows_NT' }))
      assert(resolved.name == 'curl' and resolved.command == 'curl.exe')
    end)
  end)
end

T["缺失下载器异步报告失败"] = function()
  child.lua_func(function()
    with_executables({}, function()
      local destination = vim.fn.tempname()
      vim.fn.writefile({ 'pre-existing' }, destination)
      local result
      local cancel = Download.file({
        url = 'https://example.invalid/file',
        destination = destination,
      }, function(value)
        result = value
      end)
      assert(result and result.code == 'downloader_not_found')
      assert(result.message:find('curl', 1, true))
      cancel()
      assert(vim.uv.fs_stat(destination),
        '同步失败交付后的取消不得删除目标')
      vim.fn.delete(destination)
    end)
  end)
end

T["PowerShell 使用环境传参避免 argv 泄漏"] = function()
  child.lua_func(function()
    with_executables({ ['powershell.exe'] = true }, function()
      local captured
      vim.system = function(command, opts, callback)
        captured = { command = command, opts = opts }
        vim.fn.writefile({ 'powershell fixture' }, opts.env.VV_DOWNLOAD_DESTINATION)
        callback({ code = 0, stdout = '', stderr = '' })
      end

      local powershell_dir = vim.fn.tempname()
      local powershell_destination = vim.fs.joinpath(powershell_dir, 'a b.exe')
      vim.fn.mkdir(powershell_dir, 'p')
      local result
      Download.file({
        url = 'https://example.invalid/a b.exe',
        destination = powershell_destination,
      }, function(value)
        result = value
      end)
      vim.wait(1000, function() return result ~= nil end)

      assert(result and result.ok and result.backend == 'PowerShell')
      assert(captured.command[1] == 'powershell.exe')
      assert(captured.opts.env.VV_DOWNLOAD_URL == 'https://example.invalid/a b.exe')
      assert(captured.opts.env.VV_DOWNLOAD_DESTINATION ~= powershell_destination)
      assert(vim.fs.dirname(captured.opts.env.VV_DOWNLOAD_DESTINATION) == powershell_dir)
      assert(captured.opts.env.VV_DOWNLOAD_ATTEMPTS == '4')
      assert(table.concat(vim.fn.readfile(powershell_destination), '') == 'powershell fixture')
      vim.fn.delete(powershell_dir, 'rf')
    end)
  end)
end

T["物理取消压制发布且清理等待原始退出"] = function()
  child.lua_func(function()
    local original_resolve = Download.resolve
    local cancel_tmp = vim.fn.tempname()
    local started_path = vim.fs.joinpath(cancel_tmp, 'started')
    local exited_path = vim.fs.joinpath(cancel_tmp, 'exited')
    local destination = vim.fs.joinpath(cancel_tmp, 'download')
    vim.fn.mkdir(cancel_tmp, 'p')
    local cancel_staging
    Download.resolve = function()
      return {
        name = 'fixture',
        command = '/bin/sh',
        build = function(_, _, target)
          cancel_staging = target
          return {
            '/bin/sh',
            '-c',
            [[
    printf "%s" "$$" > "$1"
    printf partial > "$2"
    trap 'printf exited > "$3"; exit 143' TERM
    while :; do sleep 0.05; done
    ]],
            '_',
            started_path,
            target,
            exited_path,
          }
        end,
      }
    end

    local callback_count = 0
    local cancel = Download.file({
      url = 'https://example.invalid/cancel',
      destination = destination,
    }, function()
      callback_count = callback_count + 1
    end)
    assert(type(cancel) == 'function', '下载必须返回取消函数')
    assert(vim.wait(1000, function() return vim.uv.fs_stat(started_path) ~= nil end),
      'fixture 下载进程未启动')
    local pid = tonumber(table.concat(vim.fn.readfile(started_path), ''))
    assert(vim.wait(1000, function() return vim.uv.fs_stat(cancel_staging) ~= nil end),
      '取消前 fixture 下载进程未创建 staging 文件')
    local original_unlink = vim.uv.fs_unlink
    local unlink_attempts = 0
    local first_unlink_blocked = true
    local cleanup_before_raw_exit = false
    vim.uv.fs_unlink = function(path)
      if path == cancel_staging then
        unlink_attempts = unlink_attempts + 1
        if first_unlink_blocked then
          first_unlink_blocked = false
          return nil, 'EBUSY'
        end
        if not vim.uv.fs_stat(exited_path) then cleanup_before_raw_exit = true end
      end
      return original_unlink(path)
    end
    cancel()
    cancel()
    assert(vim.wait(1000, function() return vim.uv.kill(pid, 0) == nil end),
      '取消必须停止真实 vim.system 进程')
    assert(vim.wait(1000, function() return vim.uv.fs_stat(cancel_staging) == nil end),
      'raw exit 后必须再次清理取消下载的 staging 文件')
    assert(callback_count == 0, '已取消下载必须压制回调')
    assert(vim.uv.fs_stat(destination) == nil, '已取消下载不得发布不完整目标')
    assert(unlink_attempts >= 2 and not cleanup_before_raw_exit,
      '取消时首次清理失败后，必须在 raw exit 之后重试清理')
    vim.uv.fs_unlink = original_unlink
  end)
end

T["成功发布后取消不删除已完成文件"] = function()
  child.lua_func(function()
    local cancel_tmp = vim.fn.tempname()
    vim.fn.mkdir(cancel_tmp, 'p')
    local completed_destination = vim.fs.joinpath(cancel_tmp, 'completed-download')
    vim.fn.writefile({ 'previous' }, completed_destination)
    local last_success_staging
    Download.resolve = function()
      return {
        name = 'fixture',
        command = '/bin/sh',
        build = function(_, _, target)
          last_success_staging = target
          return {
            '/bin/sh',
            '-c',
            'printf complete > "$1"',
            '_',
            target,
          }
        end,
      }
    end

    local completed_result
    local cancel_completed = Download.file({
      url = 'https://example.invalid/completed',
      destination = completed_destination,
    }, function(result)
      completed_result = result
    end)
    assert(vim.wait(1000, function() return completed_result ~= nil end),
      '真实 fixture 下载未交付结果')
    assert(completed_result.ok, '真实 fixture 下载必须成功')
    cancel_completed()
    cancel_completed()
    assert(table.concat(vim.fn.readfile(completed_destination), '') == 'complete',
      '成功交付结果后的取消必须保留目标')
  end)
end

T["合法长文件名发布与发布失败不损坏目标"] = function()
  child.lua_func(function()
    local cancel_tmp = vim.fn.tempname()
    local started_path = vim.fs.joinpath(cancel_tmp, 'started')
    local exited_path = vim.fs.joinpath(cancel_tmp, 'exited')
    local destination = vim.fs.joinpath(cancel_tmp, 'download')
    vim.fn.mkdir(cancel_tmp, 'p')
    local last_success_staging
    Download.resolve = function()
      return {
        name = 'fixture',
        command = '/bin/sh',
        build = function(_, _, target)
          last_success_staging = target
          return {
            '/bin/sh',
            '-c',
            'printf complete > "$1"',
            '_',
            target,
          }
        end,
      }
    end
    local long_name_dir = vim.fs.joinpath(cancel_tmp, 'long-name')
    vim.fn.mkdir(long_name_dir)
    local long_destination = vim.fs.joinpath(long_name_dir, string.rep('a', 230))
    vim.fn.writefile({ 'previous' }, long_destination)
    local long_name_result
    Download.file({
      url = 'https://example.invalid/long-name',
      destination = long_destination,
    }, function(result)
      long_name_result = result
    end)
    assert(vim.wait(1000, function() return long_name_result ~= nil end),
      '长文件名 fixture 下载未交付结果')
    assert(long_name_result.ok, '合法的长目标文件名必须允许下载')
    assert(#vim.fs.basename(last_success_staging) < 255,
      'staging 文件名长度必须独立于目标文件名')
    assert(table.concat(vim.fn.readfile(long_destination), '') == 'complete',
      '长文件名目标未收到完整下载内容')

    local blocked_destination = vim.fs.joinpath(cancel_tmp, 'blocked-destination')
    vim.fn.mkdir(blocked_destination)
    vim.fn.writefile({ 'owned' }, vim.fs.joinpath(blocked_destination, 'child'))
    local blocked_result
    Download.file({
      url = 'https://example.invalid/publish-failure',
      destination = blocked_destination,
    }, function(result)
      blocked_result = result
    end)
    assert(vim.wait(1000, function() return blocked_result ~= nil end),
      '发布失败 fixture 未交付结果')
    assert(not blocked_result.ok and blocked_result.code == 'publish_failed',
      '原子发布失败必须报告 publish_failed')
    assert(table.concat(vim.fn.readfile(vim.fs.joinpath(blocked_destination, 'child')), '') == 'owned',
      '原子发布失败不得修改已有目标')
    assert(vim.uv.fs_stat(last_success_staging) == nil,
      '原子发布失败不得残留 staging 文件')
  end)
end

T["旧下载清理不影响同目标的新请求"] = function()
  child.lua_func(function()
    local cancel_tmp = vim.fn.tempname()
    local started_path = vim.fs.joinpath(cancel_tmp, 'started')
    local exited_path = vim.fs.joinpath(cancel_tmp, 'exited')
    local destination = vim.fs.joinpath(cancel_tmp, 'download')
    vim.fn.mkdir(cancel_tmp, 'p')
    local shared_destination = vim.fs.joinpath(cancel_tmp, 'shared-download')
    local shared_a_started = vim.fs.joinpath(cancel_tmp, 'shared-a-started')
    local shared_b_started = vim.fs.joinpath(cancel_tmp, 'shared-b-started')
    local shared_calls = 0
    local shared_staging = {}
    Download.resolve = function()
      return {
        name = 'fixture',
        command = '/bin/sh',
        build = function(_, _, target)
          shared_calls = shared_calls + 1
          shared_staging[#shared_staging + 1] = target
          if shared_calls == 1 then
            return {
              '/bin/sh',
              '-c',
              [[
    printf old-partial > "$1"
    printf "%s" "$$" > "$2"
    trap 'sleep 0.25; exit 143' TERM
    while :; do sleep 0.05; done
    ]],
              '_',
              target,
              shared_a_started,
            }
          end
          return {
            '/bin/sh',
            '-c',
            'printf new-complete > "$1"; printf started > "$2"; sleep 0.6',
            '_',
            target,
            shared_b_started,
          }
        end,
      }
    end

    local old_callback_count = 0
    local cancel_old = Download.file({
      url = 'https://example.invalid/shared-a',
      destination = shared_destination,
    }, function()
      old_callback_count = old_callback_count + 1
    end)
    assert(vim.wait(1000, function()
      return vim.uv.fs_stat(shared_a_started) ~= nil
        and shared_staging[1]
        and vim.uv.fs_stat(shared_staging[1]) ~= nil
    end), '旧共享下载未创建 staging 文件')
    local old_pid = tonumber(table.concat(vim.fn.readfile(shared_a_started), ''))
    cancel_old()

    local new_result
    Download.file({
      url = 'https://example.invalid/shared-b',
      destination = shared_destination,
    }, function(result)
      new_result = result
    end)
    assert(vim.wait(1000, function()
      return vim.uv.fs_stat(shared_b_started) ~= nil
        and shared_staging[2]
        and vim.uv.fs_stat(shared_staging[2]) ~= nil
    end), '新共享下载未创建 staging 文件')
    assert(vim.uv.kill(old_pid, 0) ~= nil,
      '前置：新下载启动前旧下载不得退出')
    assert(vim.wait(2000, function() return new_result ~= nil end),
      '新共享下载未交付结果')
    assert(new_result.ok, '新共享下载必须成功')
    assert(vim.wait(1000, function() return vim.uv.kill(old_pid, 0) == nil end),
      '已取消的旧共享下载未退出')
    assert(old_callback_count == 0, '已取消的旧共享下载不得交付回调')
    assert(shared_staging[1] ~= shared_staging[2],
      '同目标的下载必须拥有不同 staging 文件')
    assert(table.concat(vim.fn.readfile(shared_destination), '') == 'new-complete',
      '旧请求取消清理不得删除新下载目标')
    assert(vim.uv.fs_stat(shared_staging[1]) == nil
        and vim.uv.fs_stat(shared_staging[2]) == nil,
      '共享下载不得残留 staging 文件')
  end)
end

return T
