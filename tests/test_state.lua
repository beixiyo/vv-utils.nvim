-- 通用状态仓库的命名空间、合并与原子持久化测试
--
-- 运行：nvim --headless --clean -l tests/test_state.lua

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.runtimepath:prepend(repo)

local State = require('vv-utils.state')
local Lock = require('vv-utils.state.lock')
local Fs = require('vv-utils.fs')
local Watch = require('vv-utils.state.watch')

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

local install_path = vim.fs.joinpath(root, 'subscribe-install.json')
local install_writer = State.register('subscribe-install', 'panel', { path = install_path })
local install_reader = State.register('subscribe-install', 'panel', { path = install_path })
assert(install_writer:set('value', 'before'))
local install_events = {}
local original_watch_subscribe = Watch.subscribe
Watch.subscribe = function(watched_path, callback)
  local unsubscribe = original_watch_subscribe(watched_path, callback)
  assert(install_writer:set('value', 'during-install'))
  return unsubscribe
end
local unsubscribe_install = install_reader:subscribe('value', function(value, previous)
  install_events[#install_events + 1] = { value = value, previous = previous }
end, { debounce_ms = 0 })
Watch.subscribe = original_watch_subscribe
assert_eq(#install_events, 0, 'subscription must not invoke the callback synchronously')
assert(vim.wait(1000, function() return #install_events == 1 end, 5),
  'a write during watcher installation must be observed')
vim.wait(100, function() return false end, 5)
assert_eq(#install_events, 1, 'watcher installation write must not trigger duplicate callbacks')
assert_eq(install_events[1].previous, 'before', 'installation write previous value')
assert_eq(install_events[1].value, 'during-install', 'installation write value')
assert(install_writer:set('value', 'during-install'))
vim.wait(100, function() return false end, 5)
assert_eq(#install_events, 1, 'same-value writes must not trigger a callback')
unsubscribe_install()

-- A state path may be a leaf symlink whose target does not exist yet. The
-- first write and the watcher must use the resolved target, not the alias.
local broken_state_parent = vim.fs.joinpath(root, 'broken-state')
local broken_state_target = vim.fs.joinpath(broken_state_parent, 'target.json')
local broken_state_alias = vim.fs.joinpath(broken_state_parent, 'alias.json')
assert(vim.fn.mkdir(broken_state_parent, 'p') == 1)
assert(vim.uv.fs_symlink('target.json', broken_state_alias))
local broken_state = State.register('cross-process', 'broken-alias', { path = broken_state_alias })
local broken_events = {}
local unsubscribe_broken = broken_state:subscribe('value', function(value, previous)
  broken_events[#broken_events + 1] = { value = value, previous = previous }
end)
assert(broken_state:set('value', 'first'), 'first write through a broken symlink should persist')
assert_eq(Fs.load_json(broken_state_target).entries['cross-process']['broken-alias'].value, 'first',
  'first write should create the symlink target')
assert(vim.wait(1000, function() return #broken_events == 1 end, 5),
  'subscription through a broken symlink should observe the first write')
assert_eq(broken_events[1].value, 'first', 'broken symlink subscription value')
assert(broken_events[1].previous == nil, 'broken symlink subscription previous value')
unsubscribe_broken()

local nested_state_real = vim.fs.joinpath(root, 'nested-state-real/sub/deeper')
local nested_state_alias_parent = vim.fs.dirname(nested_state_real)
local nested_state_ancestor = vim.fs.joinpath(nested_state_alias_parent, 'ancestor')
local nested_state_alias = vim.fs.joinpath(nested_state_alias_parent, 'alias.json')
vim.fn.mkdir(nested_state_real, 'p')
assert(vim.uv.fs_symlink('sub/deeper', nested_state_ancestor))
assert(vim.uv.fs_symlink('ancestor/../target.json', nested_state_alias))
local nested_state = State.register('cross-process', 'nested-alias', { path = nested_state_alias })
local nested_state_target = vim.fs.joinpath(nested_state_alias_parent, 'sub/target.json')
assert(nested_state:set('value', 'nested'),
  'state should write through a broken symlink whose target contains an ancestor symlink and ..')
assert_eq(Fs.load_json(nested_state_target).entries['cross-process']['nested-alias'].value, 'nested',
  'state should persist at the filesystem-resolved broken symlink target')
assert(vim.fn.filereadable(vim.fs.joinpath(nested_state_alias_parent, 'target.json')) == 0,
  'state should not write to the lexically normalized but semantically wrong target')

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
assert(vim.tbl_contains(entries, 'state.json'), 'atomic write leaves the final state file')
for _, entry in ipairs(entries) do
  assert(entry == 'state.json' or entry == 'broken-state' or entry == 'nested-state-real'
      or entry == 'subscribe-install.json',
    'atomic write leaves no temporary file: ' .. entry)
end

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

local function run_concurrent(name, processes, delay_ms)
  local start_path = vim.fs.joinpath(root, name .. '.start')
  local children = {}
  local ready_paths = {}
  local result_paths = {}

  vim.fn.delete(start_path)
  for index, option in ipairs(processes) do
    ready_paths[index] = vim.fs.joinpath(root, name .. '.ready.' .. index)
    result_paths[index] = vim.fs.joinpath(root, name .. '.result.' .. index)
    vim.fn.delete(ready_paths[index])
    vim.fn.delete(result_paths[index])
    children[index] = vim.system({
      vim.v.progpath,
      '--headless',
      '--clean',
      '-l',
      process_fixture,
    }, {
      env = {
        VV_STATE_TEST_MODE = option.mode,
        VV_STATE_TEST_PATH = option.path or process_path,
        VV_STATE_TEST_FIELD = option.field,
        VV_STATE_TEST_VALUE = option.value,
        VV_STATE_TEST_START = start_path,
        VV_STATE_TEST_READY = ready_paths[index],
        VV_STATE_TEST_RESULT = result_paths[index],
        VV_STATE_TEST_DELAY_MS = tostring(delay_ms or 0),
      },
      text = true,
    })
  end

  assert(vim.wait(10000, function()
    for _, ready_path in ipairs(ready_paths) do
      if vim.fn.filereadable(ready_path) ~= 1 then return false end
    end
    return true
  end, 5), name .. ' processes did not reach the barrier')
  assert(vim.fn.writefile({ 'go' }, start_path) == 0)

  for index, child in ipairs(children) do
    local result = child:wait()
    assert(result.code == 0,
      ('concurrent %s process %d failed: %s'):format(name, index, result.stderr))
  end

  return result_paths
end

-- Both children deliberately pause inside the real save entry point. With no
-- lock this gives both stale snapshots a chance to overwrite each other.
run_concurrent('set', {
  { mode = 'set', field = 'left', value = 'A' },
  { mode = 'set', field = 'right', value = 'B' },
}, 100)

local concurrent = Fs.load_json(process_path)
assert_eq(concurrent.entries['cross-process'].panel.left, 'A',
  'concurrent set lost the first process update')
assert_eq(concurrent.entries['cross-process'].panel.right, 'B',
  'concurrent set lost the second process update')
assert(vim.fn.filereadable(process_path .. '.lock') == 0,
  'concurrent set left its lock behind')

-- A symlink alias must share the real path lock with its target. Otherwise
-- two processes can still overwrite each other's freshly merged snapshots.
local symlink_target_path = vim.fs.joinpath(root, 'symlink-target.json')
local symlink_alias_path = vim.fs.joinpath(root, 'symlink-alias.json')
local symlink_seed = State.register('cross-process', 'symlink', { path = symlink_target_path })
assert(symlink_seed:set('seed', true))
assert(vim.uv.fs_symlink(symlink_target_path, symlink_alias_path))
run_concurrent('symlink-set', {
  { mode = 'set', path = symlink_target_path, field = 'left', value = 'A' },
  { mode = 'set', path = symlink_alias_path, field = 'right', value = 'B' },
}, 100)
local symlink_data = Fs.load_json(symlink_target_path)
assert_eq(symlink_data.entries['cross-process'].panel.left, 'A',
  'symlink-alias set lost the first process update')
assert_eq(symlink_data.entries['cross-process'].panel.right, 'B',
  'symlink-alias set lost the second process update')
assert(vim.fn.filereadable(symlink_target_path .. '.lock') == 0,
  'symlink-alias set left the real-path lock behind')
assert(vim.fn.filereadable(symlink_alias_path .. '.lock') == 0,
  'symlink-alias set created an alias-path lock')

-- Two contenders must serialize stale-lock recovery through the reaper. The
-- stale main lock is deliberately present before either child reaches the
-- barrier, so both children observe the same crashed owner.
local stale_concurrent_path = vim.fs.joinpath(root, 'stale-concurrent.json')
local stale_concurrent_lock = stale_concurrent_path .. '.lock'
assert(vim.fn.writefile({ vim.json.encode({ pid = 2147483647, token = 'crashed' }) },
  stale_concurrent_lock) == 0)
assert(vim.uv.fs_utime(stale_concurrent_lock, 1, 1))
run_concurrent('stale-concurrent', {
  { mode = 'set', path = stale_concurrent_path, field = 'left', value = 'A' },
  { mode = 'set', path = stale_concurrent_path, field = 'right', value = 'B' },
}, 100)
local stale_concurrent = Fs.load_json(stale_concurrent_path)
assert_eq(stale_concurrent.entries['cross-process'].panel.left, 'A',
  'concurrent stale recovery lost the first process update')
assert_eq(stale_concurrent.entries['cross-process'].panel.right, 'B',
  'concurrent stale recovery lost the second process update')
assert(vim.fn.filereadable(stale_concurrent_lock) == 0,
  'concurrent stale recovery left its main lock behind')
assert(vim.fn.filereadable(stale_concurrent_lock .. '.reap') == 0,
  'concurrent stale recovery left its reaper behind')

local cas_path = vim.fs.joinpath(root, 'cas.json')
local cas = State.register('cross-process', 'panel', { path = cas_path })
assert(cas:set('value', 'base'))
assert(cas:set('flag', false))
local false_mismatch, false_current = cas:compare_and_set('flag', nil, true)
assert(not false_mismatch, 'CAS must distinguish a stored false from a missing field')
assert(false_current == false, 'CAS mismatch must return the stored false value')
assert(cas:get('flag') == false, 'a failed CAS must preserve the stored false value')
local false_updated, false_value, false_error = cas:compare_and_set('flag', false, true)
assert(false_updated and false_value == true and not false_error,
  'CAS must update a stored false value')
assert(cas:set('flag', false))
local false_removed, false_removed_value, false_removed_error = cas:compare_and_set('flag', false, nil)
assert(false_removed and false_removed_value == nil and not false_removed_error,
  'CAS must delete a stored false value')
assert(cas:get('flag', 'missing') == 'missing', 'CAS delete must remove a false value')
local cas_result_paths = run_concurrent('cas', {
  { mode = 'cas', path = cas_path, value = 'A' },
  { mode = 'cas', path = cas_path, value = 'B' },
}, 150)

local cas_results = {}
for index, result_path in ipairs(cas_result_paths) do
  cas_results[index] = vim.json.decode(table.concat(vim.fn.readfile(result_path), '\n'))
end
assert((cas_results[1].updated and not cas_results[2].updated)
    or (cas_results[2].updated and not cas_results[1].updated),
  'concurrent CAS must update exactly one winner')
local winner = cas_results[1].updated and cas_results[1].current or cas_results[2].current
local loser = cas_results[1].updated and cas_results[2] or cas_results[1]
assert(loser.current == winner, 'CAS loser must observe the committed winner')
local cas_data = Fs.load_json(cas_path)
assert_eq(cas_data.entries['cross-process'].panel.value, winner,
  'CAS loser overwrote the winner')
assert(vim.fn.filereadable(cas_path .. '.lock') == 0, 'concurrent CAS left its lock behind')

-- 一个真实的 headless Neovim 订阅，另一个进程写入共享状态；验证 OS 文件
-- 事件链路而不是在测试内直接调用 callback
local subscribe_path = vim.fs.joinpath(root, 'subscribe.json')
local subscribe_handle = State.register('cross-process', 'panel', { path = subscribe_path })
assert(subscribe_handle:set('value', 'before'))
local subscribe_ready = vim.fs.joinpath(root, 'subscribe.ready')
local subscribe_result = vim.fs.joinpath(root, 'subscribe.result')
local subscriber = vim.system({
  vim.v.progpath,
  '--headless',
  '--clean',
  '-l',
  process_fixture,
}, {
  env = {
    VV_STATE_TEST_MODE = 'subscribe',
    VV_STATE_TEST_PATH = subscribe_path,
    VV_STATE_TEST_READY = subscribe_ready,
    VV_STATE_TEST_RESULT = subscribe_result,
  },
  text = true,
})
assert(vim.wait(10000, function() return vim.fn.filereadable(subscribe_ready) == 1 end, 5),
  'state subscriber did not become ready')
assert(subscribe_handle:set('value', 'after'))
local subscriber_result = subscriber:wait()
assert(subscriber_result.code == 0, 'state subscriber failed: ' .. subscriber_result.stderr)
local observed = vim.json.decode(table.concat(vim.fn.readfile(subscribe_result), '\n'))
assert_eq(observed.previous, 'before', 'subscriber previous value')
assert_eq(observed.value, 'after', 'subscriber value written by another process')

local local_events = {}
local unsubscribe = subscribe_handle:subscribe('value', function(value)
  local_events[#local_events + 1] = value
end)
assert(subscribe_handle:set('value', 'local-change'))
assert(vim.wait(1000, function() return #local_events == 1 end, 5),
  'local state subscription did not observe a file change')
unsubscribe()
unsubscribe()
assert(subscribe_handle:set('value', 'after-unsubscribe'))
vim.wait(100, function() return false end, 5)
assert_eq(#local_events, 1, 'unsubscribe must stop future callbacks')

-- The watcher key must use the same canonical path as the store. A write via
-- the real target must notify a subscription registered through its symlink.
local alias_watch_target = vim.fs.joinpath(root, 'alias-watch-target.json')
local alias_watch_path = vim.fs.joinpath(root, 'alias-watch.json')
local alias_watch_writer = State.register('cross-process', 'alias-watch', { path = alias_watch_target })
assert(alias_watch_writer:set('value', 'before'))
assert(vim.uv.fs_symlink(alias_watch_target, alias_watch_path))
local alias_watch = State.register('cross-process', 'alias-watch', { path = alias_watch_path })
local alias_events = {}
local unsubscribe_alias = alias_watch:subscribe('value', function(value, previous)
  alias_events[#alias_events + 1] = { value = value, previous = previous }
end)
assert(alias_watch_writer:set('value', 'after'))
assert(vim.wait(1000, function() return #alias_events == 1 end, 5),
  'symlink-alias subscription did not observe a real-path write')
assert_eq(alias_events[1].previous, 'before', 'symlink-alias subscription previous value')
assert_eq(alias_events[1].value, 'after', 'symlink-alias subscription value')
unsubscribe_alias()

local cancelled_events = 0
local unsubscribe_pending = subscribe_handle:subscribe('value', function()
  cancelled_events = cancelled_events + 1
end, { debounce_ms = 50 })
assert(subscribe_handle:set('value', 'pending-unsubscribe'))
vim.wait(10, function() return false end, 1)
unsubscribe_pending()
vim.wait(100, function() return false end, 5)
assert_eq(cancelled_events, 0, 'unsubscribe must suppress a pending callback')

local stale_path = vim.fs.joinpath(root, 'stale.json')
local stale_lock_path = stale_path .. '.lock'
local stale_handle = State.register('cross-process', 'stale', {
  path = stale_path,
  lock_timeout_ms = 100,
  lock_stale_ms = 10,
  lock_retry_ms = 2,
})
assert(vim.fn.writefile({ vim.json.encode({ pid = 2147483647, token = 'crashed' }) }, stale_lock_path) == 0)
assert(vim.uv.fs_utime(stale_lock_path, 1, 1))
assert(stale_handle:set('value', 'recovered'), 'stale lock should be reclaimed')
assert(vim.fn.filereadable(stale_lock_path) == 0, 'reclaimed stale lock should be released')

-- Replacing the stale entry between inspection and removal must not delete the
-- replacement. The uv wrappers make this race deterministic: the old unlink
-- implementation would remove the injected owner, while the atomic
-- quarantine path restores it and waits for its live owner to release it.
local reclaim_race_path = vim.fs.joinpath(root, 'reclaim-race.json')
local reclaim_race_lock = reclaim_race_path .. '.lock'
assert(vim.fn.writefile({ vim.json.encode({
  pid = 2147483647,
  token = 'crashed-before-replacement',
}) }, reclaim_race_lock) == 0)
assert(vim.uv.fs_utime(reclaim_race_lock, 1, 1))
local reclaim_race_handle = State.register('cross-process', 'reclaim-race', {
  path = reclaim_race_path,
  lock_timeout_ms = 40,
  lock_stale_ms = 10,
  lock_retry_ms = 2,
})
local original_rename = vim.uv.fs_rename
local original_unlink = vim.uv.fs_unlink
local replacement_injected = false
local replacement_deleted = false
local function inject_replacement()
  assert(original_unlink(reclaim_race_lock))
  assert(vim.fn.writefile({ vim.json.encode({
    pid = vim.uv.os_getpid(),
    token = 'replacement-owner',
  }) }, reclaim_race_lock) == 0)
  assert(vim.uv.fs_chmod(reclaim_race_lock, 384))
  replacement_injected = true
end
vim.uv.fs_rename = function(source, destination)
  if source == reclaim_race_lock and not replacement_injected
      and destination:find('.stale.', 1, true)
  then
    inject_replacement()
  end
  return original_rename(source, destination)
end
vim.uv.fs_unlink = function(target)
  if target == reclaim_race_lock and not replacement_injected then
    inject_replacement()
    local removed, remove_error = original_unlink(target)
    if removed then replacement_deleted = true end
    return removed, remove_error
  end
  return original_unlink(target)
end
local reclaim_race_ok, reclaim_race_result = pcall(
  reclaim_race_handle.set,
  reclaim_race_handle,
  'value',
  'must-not-overwrite'
)
vim.uv.fs_rename = original_rename
vim.uv.fs_unlink = original_unlink
assert(reclaim_race_ok, 'stale-lock replacement must not escape the state write API')
assert(replacement_injected, 'the deterministic stale-lock replacement was not reached')
assert(not reclaim_race_result, 'a live replacement owner must not be overwritten')
assert(not replacement_deleted, 'stale recovery deleted the replacement owner')
local replacement_owner = vim.json.decode(table.concat(vim.fn.readfile(reclaim_race_lock), '\n'))
assert(replacement_owner.token == 'replacement-owner',
  'stale recovery must preserve the replacement lock owner')

-- Main-lock creation must respect a live reaper gate even when the main lock
-- is absent. Older acquire paths ignored this gate and could enter while a
-- stale-lock reaper was validating its ownership window.
local live_reaper_path = vim.fs.joinpath(root, 'live-reaper.json')
local live_reaper_lock = live_reaper_path .. '.lock'
local live_reaper_gate = live_reaper_lock .. '.reap'
assert(vim.fn.writefile({ vim.json.encode({
  pid = vim.uv.os_getpid(),
  token = 'live-reaper',
}) }, live_reaper_gate) == 0)
local live_reaper_handle = State.register('cross-process', 'live-reaper', {
  path = live_reaper_path,
  lock_timeout_ms = 30,
  lock_stale_ms = 10,
  lock_retry_ms = 2,
})
local live_reaper_ok, live_reaper_result = pcall(
  live_reaper_handle.set,
  live_reaper_handle,
  'value',
  'must-not-enter'
)
assert(live_reaper_ok, 'a live reaper gate must not escape the state write API')
assert(not live_reaper_result, 'a live reaper gate must block main-lock creation')
assert(vim.fn.filereadable(live_reaper_lock) == 0,
  'a blocked acquire must not create the main lock behind a live reaper')
assert(vim.fn.filereadable(live_reaper_gate) == 1,
  'a live reaper gate must remain owned by its creator')

-- Restoring a quarantined stale reaper must not replace a newer reaper that
-- appeared while the old entry was being isolated. The wrapper models two
-- other contenders around the real Lock.acquire call: B reaps the old gate,
-- then C acquires the newly empty gate before the first contender restores B.
local reaper_replace_path = vim.fs.joinpath(root, 'reaper-replace.json')
local reaper_replace_lock = reaper_replace_path .. '.lock'
local reaper_replace_gate = reaper_replace_lock .. '.reap'
assert(vim.fn.writefile({ vim.json.encode({
  pid = 2147483647,
  token = 'stale-reaper-before-replacement',
}) }, reaper_replace_gate) == 0)
assert(vim.uv.fs_utime(reaper_replace_gate, 1, 1))
local reaper_replace_handle = State.register('cross-process', 'reaper-replace', {
  path = reaper_replace_path,
  lock_timeout_ms = 100,
  lock_stale_ms = 10,
  lock_retry_ms = 2,
})
local replace_original_rename = vim.uv.fs_rename
local replace_original_notify = vim.notify
local replace_quarantine
local replace_injected = false
local replace_notices = {}
vim.uv.fs_rename = function(source, destination)
  if source == reaper_replace_gate and destination:find('.stale.', 1, true)
      and not replace_injected
  then
    -- B moves the stale gate and publishes its replacement before the first
    -- contender gets to rename the path it just inspected.
    local moved, move_error = replace_original_rename(
      source,
      reaper_replace_gate .. '.stale.B'
    )
    assert(moved, move_error)
    assert(vim.fn.writefile({ vim.json.encode({
      pid = vim.uv.os_getpid(),
      token = 'reaper-B',
    }) }, reaper_replace_gate) == 0)
    local moved_replacement, replacement_error = replace_original_rename(source, destination)
    assert(moved_replacement, replacement_error)
    replace_quarantine = destination
    -- C acquires the path while B is held in the first contender's quarantine.
    assert(vim.fn.writefile({ vim.json.encode({
      pid = vim.uv.os_getpid(),
      token = 'reaper-C',
    }) }, reaper_replace_gate) == 0)
    replace_injected = true
    return moved_replacement, replacement_error
  end
  return replace_original_rename(source, destination)
end
vim.notify = function(message, level)
  replace_notices[#replace_notices + 1] = { message = message, level = level }
end
local reaper_replace_ok, reaper_replace_result = pcall(
  reaper_replace_handle.set,
  reaper_replace_handle,
  'value',
  'must-not-overwrite-new-reaper'
)
vim.uv.fs_rename = replace_original_rename
vim.notify = replace_original_notify
assert(reaper_replace_ok, 'new reaper replacement must not escape the state write API')
assert(not reaper_replace_result, 'a failed stale reaper restore must reject the state write')
assert(replace_injected, 'the stale reaper replacement race was not reached')
assert(vim.fn.filereadable(reaper_replace_gate) == 1,
  'stale reaper restore must preserve the newer reaper')
local replacement_reaper_owner = vim.json.decode(
  table.concat(vim.fn.readfile(reaper_replace_gate), '\n')
)
assert(replacement_reaper_owner.token == 'reaper-C',
  'stale reaper restore must not overwrite the newer reaper owner')
assert(replace_quarantine and vim.fn.filereadable(replace_quarantine) == 1,
  'failed stale reaper restore must retain the quarantined owner')
local replace_notice_text = {}
for _, notice in ipairs(replace_notices) do
  replace_notice_text[#replace_notice_text + 1] = tostring(notice.message)
end
assert(table.concat(replace_notice_text, '\n'):find('failed to restore stale state reaper', 1, true),
  'stale reaper restore failure must be reported to the caller')

-- A stale reaper quarantine that cannot be restored must abort acquisition;
-- it must not continue by creating a new gate while the old entry is hidden.
local reaper_failure_path = vim.fs.joinpath(root, 'reaper-restore-failure.json')
local reaper_failure_lock = reaper_failure_path .. '.lock'
local reaper_failure_gate = reaper_failure_lock .. '.reap'
assert(vim.fn.writefile({ vim.json.encode({
  pid = 2147483647,
  token = 'stale-reaper',
}) }, reaper_failure_gate) == 0)
assert(vim.uv.fs_utime(reaper_failure_gate, 1, 1))
local reaper_failure_handle = State.register('cross-process', 'reaper-restore-failure', {
  path = reaper_failure_path,
  lock_timeout_ms = 100,
  lock_stale_ms = 10,
  lock_retry_ms = 2,
})
local failure_original_rename = vim.uv.fs_rename
local failure_original_link = vim.uv.fs_link
local failure_original_unlink = vim.uv.fs_unlink
local failure_quarantine
local failure_unlink_attempted = false
local failure_restore_attempted = false
vim.uv.fs_rename = function(source, destination)
  if source == reaper_failure_gate and destination:find('.stale.', 1, true) then
    local moved, move_error = failure_original_rename(source, destination)
    if moved then failure_quarantine = destination end
    return moved, move_error
  end
  if source == failure_quarantine and destination == reaper_failure_gate then
    failure_restore_attempted = true
    return nil, 'EACCES: injected reaper restore failure'
  end
  return failure_original_rename(source, destination)
end
vim.uv.fs_link = function(source, destination)
  if source == failure_quarantine then
    return nil, 'EACCES: injected stale reaper restore link failure'
  end
  return failure_original_link(source, destination)
end
vim.uv.fs_unlink = function(target)
  if target == failure_quarantine then
    failure_unlink_attempted = true
    return nil, 'EACCES: injected stale reaper unlink failure'
  end
  return failure_original_unlink(target)
end
local reaper_failure_ok, reaper_failure_result = pcall(
  reaper_failure_handle.set,
  reaper_failure_handle,
  'value',
  'must-not-commit'
)
vim.uv.fs_rename = failure_original_rename
vim.uv.fs_link = failure_original_link
vim.uv.fs_unlink = failure_original_unlink
assert(reaper_failure_ok, 'reaper restore failure must not escape the state write API')
assert(not reaper_failure_result, 'reaper restore failure must reject the state write')
assert(failure_unlink_attempted and not failure_restore_attempted,
  'reaper restore must stop after a failed no-replace link')
assert(vim.fn.filereadable(reaper_failure_lock) == 0,
  'reaper restore failure must not create the main lock')
assert(vim.fn.filereadable(reaper_failure_gate) == 0,
  'reaper restore failure must not recreate the gate')
assert(vim.fn.filereadable(failure_quarantine) == 1,
  'failed reaper restore must retain the quarantined entry')

-- A transient unlink failure for our own release quarantine is retryable, but
-- an ownership mismatch with a failed restore is terminal and repeatable.
local release_retry_path = vim.fs.joinpath(root, 'release-retry.json')
local release_retry_lock = assert(Lock.acquire(release_retry_path, {
  timeout_ms = 100,
  stale_ms = 10,
  retry_ms = 2,
}))
local release_original_rename = vim.uv.fs_rename
local release_original_unlink = vim.uv.fs_unlink
local release_quarantine
local release_unlink_attempts = 0
vim.uv.fs_rename = function(source, destination)
  if source == release_retry_lock.path and destination:find('.release.', 1, true) then
    release_quarantine = destination
  end
  return release_original_rename(source, destination)
end
vim.uv.fs_unlink = function(target)
  if target == release_quarantine and release_unlink_attempts == 0 then
    release_unlink_attempts = release_unlink_attempts + 1
    return nil, 'EACCES: injected release unlink failure'
  end
  return release_original_unlink(target)
end
local first_release_ok, first_release_error = release_retry_lock:release()
local second_release_ok, second_release_error = release_retry_lock:release()
vim.uv.fs_rename = release_original_rename
vim.uv.fs_unlink = release_original_unlink
assert(not first_release_ok and first_release_error, 'first release failure must be reported')
assert(second_release_ok, 'a later release call must retry our own quarantine unlink')
assert(vim.fn.filereadable(release_retry_lock.path) == 0,
  'a successful release retry must remove the main lock')
assert(vim.fn.filereadable(release_quarantine) == 0,
  'a successful release retry must remove its quarantine')
assert(release_retry_lock:release(), 'release remains idempotent after a successful retry')

local release_mismatch_path = vim.fs.joinpath(root, 'release-mismatch.json')
local release_mismatch_lock = assert(Lock.acquire(release_mismatch_path, {
  timeout_ms = 100,
  stale_ms = 10,
  retry_ms = 2,
}))
local mismatch_original_rename = vim.uv.fs_rename
local mismatch_original_link = vim.uv.fs_link
local mismatch_original_unlink = vim.uv.fs_unlink
local mismatch_quarantine
local mismatch_restore_attempts = 0
vim.uv.fs_rename = function(source, destination)
  if source == release_mismatch_lock.path and destination:find('.release.', 1, true) then
    local moved, move_error = mismatch_original_rename(source, destination)
    if moved then
      mismatch_quarantine = destination
      assert(vim.fn.writefile({ vim.json.encode({
        pid = vim.uv.os_getpid(),
        token = 'different-owner',
      }) }, destination) == 0)
    end
    return moved, move_error
  end
  return mismatch_original_rename(source, destination)
end
vim.uv.fs_link = function(source, destination)
  if source == mismatch_quarantine and destination == release_mismatch_lock.path then
    mismatch_restore_attempts = mismatch_restore_attempts + 1
    return nil, 'EACCES: injected ownership restore failure'
  end
  return mismatch_original_link(source, destination)
end
local mismatch_first_ok, mismatch_first_error = release_mismatch_lock:release()
local mismatch_second_ok, mismatch_second_error = release_mismatch_lock:release()
vim.uv.fs_rename = mismatch_original_rename
vim.uv.fs_link = mismatch_original_link
vim.uv.fs_unlink = mismatch_original_unlink
assert(not mismatch_first_ok and not mismatch_second_ok,
  'ownership mismatch must remain a release failure')
assert(mismatch_first_error == mismatch_second_error,
  'ownership mismatch restore failure must remain the same failure on retry')
assert(mismatch_restore_attempts == 1,
  'terminal ownership mismatch must not repeatedly mutate the quarantine')
assert(vim.fn.filereadable(release_mismatch_lock.path) == 0,
  'failed ownership restore must not create a replacement main lock')
assert(vim.fn.filereadable(mismatch_quarantine) == 1,
  'failed ownership restore must retain the non-owner quarantine')

local invalid_stale_path = vim.fs.joinpath(root, 'invalid-stale.json')
local invalid_stale_lock_path = invalid_stale_path .. '.lock'
local invalid_stale_handle = State.register('cross-process', 'invalid-stale', {
  path = invalid_stale_path,
  lock_timeout_ms = 100,
  lock_stale_ms = 10,
  lock_retry_ms = 2,
})
assert(vim.fn.mkdir(invalid_stale_lock_path, 'p') == 1)
assert(vim.uv.fs_utime(invalid_stale_lock_path, 1, 1))
local invalid_stale_ok, invalid_stale_result = pcall(
  invalid_stale_handle.set,
  invalid_stale_handle,
  'invalid',
  'lock'
)
assert(invalid_stale_ok, 'an invalid stale lock must not escape the state write API')
assert(not invalid_stale_result, 'an invalid stale lock must return false from set')
assert(vim.fn.isdirectory(invalid_stale_lock_path) == 1,
  'an invalid stale lock must remain untouched when it cannot be reclaimed')

local timeout_path = vim.fs.joinpath(root, 'timeout.json')
local timeout_lock_path = timeout_path .. '.lock'
local timeout_handle = State.register('cross-process', 'timeout', {
  path = timeout_path,
  lock_timeout_ms = 30,
  lock_stale_ms = 1,
  lock_retry_ms = 2,
})
assert(vim.fn.writefile({ vim.json.encode({ pid = vim.uv.os_getpid(), token = 'live' }) }, timeout_lock_path) == 0)
assert(vim.uv.fs_utime(timeout_lock_path, 1, 1))
assert(not timeout_handle:set('value', 'blocked'), 'live lock should time out instead of being reclaimed')
assert(vim.fn.filereadable(timeout_lock_path) == 1, 'timed out lock must remain owned')
assert(vim.uv.fs_unlink(timeout_lock_path))

cleanup()
print('PASS: vv-utils state namespace, CAS, and concurrent persistence behavior')
