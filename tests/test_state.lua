-- 通用状态仓库的命名空间、合并与原子持久化测试
--
-- 运行：nvim --headless --clean -l tests/test_state.lua

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.runtimepath:prepend(repo)

local State = require('vv-utils.state')

local root = vim.fs.joinpath('/tmp', 'vv-utils-state-test-' .. vim.uv.os_getpid())
local path = vim.fs.joinpath(root, 'state.json')

local function cleanup()
  vim.fn.delete(root, 'rf')
end

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error(string.format('%s: expected %q, got %q', message, expected, actual))
  end
end

cleanup()

assert(not pcall(State.register, '..', 'panel'), 'plugin id must not escape the state namespace')
assert(not pcall(State.register, 'vv-i18n', '../panel'), 'key id must use safe characters')

local references = State.register('vv-i18n', 'references', { path = path })
local explorer = State.register('vv-explorer', 'panel', { path = path })

assert_eq(references:get('width', 62), 62, 'missing field returns its default')
assert(references:set('width', 41), 'width should persist')
assert(explorer:set('width', 32), 'another plugin namespace should persist')

local reloaded = State.register('vv-i18n', 'references', { path = path })
assert_eq(reloaded:get('width'), 41, 'a new handle reloads persisted state')

-- 模拟另一个 Neovim 在当前 handle 存活期间写入同一个文件
local external = require('vv-utils.fs').load_json(path)
external.entries.external = {
  panel = {
    width = 27,
  },
}
require('vv-utils.fs').save_json(path, external)

assert(references:set('position', 'right'), 'local update should merge the latest disk snapshot')
local merged = require('vv-utils.fs').load_json(path)
assert_eq(merged.entries.external.panel.width, 27, 'external namespace survives a local update')
assert_eq(merged.entries['vv-explorer'].panel.width, 32, 'another registered namespace survives')
assert_eq(merged.entries['vv-i18n'].references.width, 41, 'existing fields under the same key survive')
assert_eq(merged.entries['vv-i18n'].references.position, 'right', 'new field is persisted')

assert(references:remove('position'), 'field removal should persist')
assert_eq(references:get('position', 'left'), 'left', 'removed field falls back to default')

local stat = assert(vim.uv.fs_stat(path))
assert_eq(stat.mode % 512, 384, 'state file permissions are 0600')

local entries = vim.fn.readdir(root)
assert_eq(#entries, 1, 'atomic write leaves no temporary file')
assert_eq(entries[1], 'state.json', 'only the final state file remains')

vim.fn.writefile({ '{broken' }, path)
local notices = {}
local notify = vim.notify
vim.notify = function(message) notices[#notices + 1] = message end
assert_eq(references:get('width', 62), 62, 'corrupted state reads fall back without exposing invalid data')
assert(not references:set('width', 99), 'corrupted state must reject writes')
vim.notify = notify
assert(#notices >= 2, 'corrupted state should warn on reads and rejected writes')
assert_eq(vim.fn.readfile(path)[1], '{broken', 'corrupted state must not be silently overwritten')

local process_path = vim.fs.joinpath(root, 'cross-process.json')
local process_fixture = vim.fs.joinpath(repo, 'tests', 'state_process_fixture.lua')
local function run_process(mode)
  local result = vim.system({
    vim.v.progpath,
    '--headless',
    '--clean',
    '-l',
    process_fixture,
  }, {
    env = {
      VV_STATE_TEST_MODE = mode,
      VV_STATE_TEST_PATH = process_path,
    },
    text = true,
  }):wait()

  assert(result.code == 0, ('cross-process %s failed: %s'):format(mode, result.stderr))
end

run_process('write')
run_process('read')

cleanup()
print('PASS: vv-utils state namespace and persistence behavior')
