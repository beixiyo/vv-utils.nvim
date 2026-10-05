-- 每个场景在独立 child Neovim 内运行；父 hook 始终回收进程与隔离临时 fixture
local M = {}
local Processes = dofile(assert(vim.env.VV_UTILS) .. '/dev/test/process.lua')

function M.eq(actual, expected, message)
  assert(vim.deep_equal(actual, expected), (message or '值不一致') .. '\n期望：'
    .. vim.inspect(expected) .. '\n实际：' .. vim.inspect(actual))
end

-- 子进程内安装；异步异常留到父 hook 断言，不能被回调边界静默吞掉
function M.install()
  M.errors, M.processes = {}, {}
  local root, sequence = assert(vim.env.VV_TEST_TMP), 0
  vim.fn.mkdir(root .. '/tmp', 'p')
  vim.fn.tempname = function()
    sequence = sequence + 1
    return root .. '/tmp/临时-' .. sequence
  end
  for _, name in ipairs({ 'CONFIG', 'DATA', 'STATE', 'CACHE' }) do
    vim.env['XDG_' .. name .. '_HOME'] = root .. '/' .. name:lower()
  end
  vim.env.HOME, vim.env.TMPDIR = root .. '/home', root
  vim.fn.mkdir(vim.env.HOME, 'p')
  vim.cmd.cd(vim.fn.fnameescape(root))
  -- 路径复制契约不需要触碰用户的系统剪贴板
  local clipboard = {}
  local function copy(lines, regtype)
    clipboard = { lines, regtype }
  end
  local function paste()
    return clipboard[1] or {}, clipboard[2] or 'v'
  end
  vim.g.clipboard = { name = '测试隔离', copy = { ['+'] = copy, ['*'] = copy },
    paste = { ['+'] = paste, ['*'] = paste } }
  local schedule = vim.schedule
  vim.schedule = function(callback)
    schedule(function()
      local ok, err = xpcall(callback, debug.traceback)
      if not ok then
        M.errors[#M.errors + 1] = tostring(err)
      end
    end)
  end
  local system = vim.system
  vim.system = function(...)
    local process = system(...)
    M.processes[#M.processes + 1] = process
    return process
  end
end

function M.new_set(setup)
  local MiniTest = require('mini.test')
  local child = MiniTest.new_child_neovim()
  local root, pid
  local T = MiniTest.new_set({
    hooks = {
      pre_case = function()
        pid = nil
        -- case 留在共享 scratch 内，信号中断时也能清理；短名称避免 RPC socket 超长
        root = assert(vim.uv.fs_mkdtemp(assert(vim.env.TMPDIR) .. '/uXXXXXX'))
        root = assert(vim.uv.fs_realpath(root))
        local environment = {
          HOME = root .. '/home', TMPDIR = root .. '/tmp', VV_TEST_TMP = root,
          XDG_CONFIG_HOME = root .. '/config', XDG_DATA_HOME = root .. '/data',
          XDG_STATE_HOME = root .. '/state', XDG_CACHE_HOME = root .. '/cache',
          XDG_RUNTIME_DIR = root .. '/runtime',
        }
        local previous = {}
        for key, value in pairs(environment) do
          vim.fn.mkdir(value, 'p')
          previous[key], vim.env[key] = vim.env[key], value
        end
        -- RPC socket 与启动期环境属于本 case；失败连接也必须归还父环境
        local tempname = vim.fn.tempname
        vim.fn.tempname = function()
          return root .. '/child.sock'
        end
        local started, start_error = pcall(child.start, {
          '-u', 'NONE', '-i', 'NONE', '-n', '--cmd', 'cd ' .. vim.fn.fnameescape(root),
        }, { nvim_executable = vim.v.progpath })
        vim.fn.tempname = tempname
        for key in pairs(environment) do
          vim.env[key] = previous[key]
        end
        if child.job then
          pid = vim.fn.jobpid(child.job.id)
        end
        assert(started, '启动隔离子进程失败：' .. tostring(start_error))
        child.lua([[
        vim.opt.packpath = ''
        dofile(vim.env.VV_UTILS .. '/dev/test/runtime.lua').apply()
        vim.opt.runtimepath:prepend(vim.env.VV_TEST_REPO)
        vim.opt.runtimepath:prepend(vim.env.VV_UTILS)
        Helpers = dofile(vim.env.VV_TEST_REPO .. '/tests/helpers.lua')
        Helpers.install()
      ]])
        if setup then
          child.lua_func(setup)
        end
      end,
      post_case = function()
        local ok, errors = pcall(function()
          -- 只检查捕获的异步异常；预期 autocmd / Ex 错误由场景自身精确断言
          return child.lua_get('Helpers.errors')
        end)
        local descendants_ok, descendants_error = pcall(Processes.stop_descendants, pid)
        -- 同步 RPC 失败也可能留下并发 state fixture；先回收它们再停止 RPC child
        pcall(function()
          child.lua([[
          for _, process in ipairs(Helpers.processes) do
            pcall(process.kill, process, 'sigkill')
            pcall(process.wait, process, 1000)
          end
        ]])
        end)
        local stopped, stop_error = pcall(child.stop)
        if root then
          -- 失败可能发生在 chmod 000 / 0555 之后，恢复目录权限才能完整清理
          vim.system({ 'chmod', '-R', 'u+rwX', root }):wait()
          assert(vim.fn.delete(root, 'rf') == 0, '未能清理临时 fixture：' .. root)
        end
        assert(stopped, stop_error)
        assert(descendants_ok, descendants_error)
        assert(ok, '无法取得子进程异步错误：' .. tostring(errors))
        M.eq(errors, {}, '异步回调不得留下未处理异常')
      end,
    },
  })
  return T, child
end

return M
