-- 收集 mini.test named sets，并把收集错误、空集合、超时和行为失败传为非零退出
local function main()
  local runner = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
  local repo = assert(arg[1], 'usage: run.sh <plugin-root> [literal-filter]')
  repo = vim.fn.fnamemodify(repo, ':p'):gsub('/$', '')
  local filter = arg[2] or ''
  local utils = vim.env.VV_UTILS or vim.fs.dirname(vim.fs.dirname(runner))
  utils = vim.fn.fnamemodify(utils, ':p'):gsub('/$', '')
  if vim.env.VV_TEST_DEPS_CACHE then
    vim.env.VV_TEST_DEPS_CACHE = vim.fn.fnamemodify(vim.env.VV_TEST_DEPS_CACHE, ':p'):gsub('/$', '')
  end
  vim.env.VV_UTILS = utils
  vim.env.VV_TEST_REPO = repo
  vim.cmd.cd(vim.fn.fnameescape(repo))
  vim.opt.runtimepath:prepend(repo)
  vim.opt.runtimepath:prepend(utils)
  local deps = dofile(vim.fs.joinpath(runner, 'deps.lua'))
  vim.opt.runtimepath:prepend(deps.ensure_mini_test())
  local MiniTest = require('mini.test')
  MiniTest.setup()
  local cases = MiniTest.collect({
    emulate_busted = false,
    find_files = function() return vim.fn.glob('tests/**/test_*.lua', false, true) end,
    filter_cases = function(case) return table.concat(case.desc, ' | '):find(filter, 1, true) ~= nil end,
  })
  assert(#cases > 0, 'no test cases matched: ' .. filter)
  -- parent 的 RPC socket 临时目录按 suite 持有，不能在首个 case 清理时一并删除
  vim.fn.tempname()
  local reporter = MiniTest.gen_reporter.stdout({ quit_on_finish = false })
  local finish = reporter.finish
  local finished = false
  reporter.finish = function()
    finish()
    finished = true
  end
  MiniTest.execute(cases, { reporter = reporter })
  local completed = vim.wait(300000, function() return finished end, 10)
  MiniTest.stop()
  assert(completed, 'test suite timed out after 300 seconds')
  for _, case in ipairs(cases) do
    if not case.exec or #case.exec.fails > 0 then return false end
  end
  return true
end

local ok, result = xpcall(main, debug.traceback)
local MiniTest = package.loaded['mini.test']
if MiniTest then pcall(MiniTest.stop) end
if not ok then io.stderr:write(tostring(result) .. '\n') end
vim.cmd((ok and result) and '0cquit' or '1cquit')
