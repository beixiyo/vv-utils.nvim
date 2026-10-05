-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  repo = vim.fn.fnamemodify((vim.env.VV_TEST_REPO .. '/tests/test_state.lua'), ':p:h:h')
  vim.opt.runtimepath:prepend(repo)

  State = require('vv-utils.state')
  Lock = require('vv-utils.state.lock')
  Fs = require('vv-utils.fs')
  Watch = require('vv-utils.state.watch')

  -- macOS 的 /tmp 是 /private/tmp 的符号链接；生产代码锁路径经 Fs.realpath 规范化，
  -- 下面按路径字符串匹配的 uv 注入点必须使用同一规范路径，否则永远不会命中
  tmp_root = vim.uv.fs_realpath('/tmp') or '/tmp'
  -- 业务存储夹具与启动期 XDG_STATE_HOME 分开，原子写入检查不能混入 Neovim 自身日志目录
  root = vim.env.VV_TEST_TMP .. '/state-fixture'
  vim.fn.mkdir(root, 'p')
  path = vim.fs.joinpath(root, 'state.json')

  function cleanup()
    vim.fn.delete(root, 'rf')
  end

  function assert_eq(actual, expected, message)
    if actual ~= expected then
      error(string.format('%s: expected %q, got %q', message, expected, actual))
    end
  end
  process_path = vim.fs.joinpath(root, 'cross-process.json')
  process_fixture = vim.fs.joinpath(repo, 'tests', 'state_process_fixture.lua')

  function run_concurrent(name, processes, delay_ms)
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
    end, 5), name .. ' 进程未到达同步屏障')
    assert(vim.fn.writefile({ 'go' }, start_path) == 0)

    for index, child in ipairs(children) do
      local result = child:wait()
      assert(result.code == 0,
        ('并发 %s 进程 %d 失败：%s'):format(name, index, result.stderr))
    end

    return result_paths
  end
end)

T["命名空间隔离、外部合并、删除与损坏状态保护"] = function()
  child.lua_func(function()
    assert(not pcall(State.register, '..', 'panel'), '插件编号不得越出状态命名空间')
    assert(not pcall(State.register, 'vv-i18n', '../panel'), '状态键编号必须使用安全字符')

    local references = State.register('vv-i18n', 'references', { path = path })
    local explorer = State.register('vv-explorer', 'panel', { path = path })

    assert_eq(references:get('width', 62), 62, '缺失字段必须返回默认值')
    assert(references:set('width', 41), '宽度必须持久化')
    assert(explorer:set('width', 32), '另一个插件命名空间必须持久化')

    local reloaded = State.register('vv-i18n', 'references', { path = path })
    assert_eq(reloaded:get('width'), 41, '新句柄必须重新加载持久状态')

    -- 模拟另一个 Neovim 在当前 handle 存活期间写入同一个文件
    local external = require('vv-utils.fs').load_json(path)
    external.entries.external = {
      panel = {
        width = 27,
      },
    }
    require('vv-utils.fs').save_json(path, external)

    assert(references:set('position', 'right'), '本地更新必须合并最新磁盘快照')
    local merged = require('vv-utils.fs').load_json(path)
    assert_eq(merged.entries.external.panel.width, 27, '本地更新必须保留外部命名空间')
    assert_eq(merged.entries['vv-explorer'].panel.width, 32, '必须保留其他已注册命名空间')
    assert_eq(merged.entries['vv-i18n'].references.width, 41, '必须保留同键下的已有字段')
    assert_eq(merged.entries['vv-i18n'].references.position, 'right', '新字段必须持久化')

    assert(references:remove('position'), '字段删除必须持久化')
    assert_eq(references:get('position', 'left'), 'left', '已删除字段必须回退为默认值')

    local stat = assert(vim.uv.fs_stat(path))
    assert_eq(stat.mode % 512, 384, '状态文件权限必须为 0600')

    local entries = vim.fn.readdir(root)
    assert(vim.tbl_contains(entries, 'state.json'), '原子写入必须保留最终状态文件')
    for _, entry in ipairs(entries) do
      assert(entry == 'state.json' or entry == 'broken-state' or entry == 'nested-state-real'
          or entry == 'subscribe-install.json',
        '原子写入不得残留临时文件：' .. entry)
    end

    vim.fn.writefile({ '{broken' }, path)
    local notices = {}
    local notify = vim.notify
    vim.notify = function(message) notices[#notices + 1] = message end
    assert_eq(references:get('width', 62), 62, '读取损坏状态必须回退且不暴露非法数据')
    assert(not references:set('width', 99), '损坏状态必须拒绝写入')
    vim.notify = notify
    assert(#notices >= 2, '损坏状态的读取与拒绝写入必须通知警告')
    assert_eq(vim.fn.readfile(path)[1], '{broken', '损坏状态不得被静默覆盖')
  end)
end

T["安装 watcher 期间的写入异步通知且不重复"] = function()
  child.lua_func(function()
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
    assert_eq(#install_events, 0, '订阅不得同步调用回调')
    assert(vim.wait(1000, function() return #install_events == 1 end, 5),
      '安装 watcher 期间的写入必须被观察到')
    vim.wait(100, function() return false end, 5)
    assert_eq(#install_events, 1, '安装 watcher 期间的写入不得触发重复回调')
    assert_eq(install_events[1].previous, 'before', '安装时写入的前值')
    assert_eq(install_events[1].value, 'during-install', '安装时写入的新值')
    assert(install_writer:set('value', 'during-install'))
    vim.wait(100, function() return false end, 5)
    assert_eq(#install_events, 1, '写入相同值不得触发回调')
    unsubscribe_install()
  end)
end

T["失效符号链接首次写入与订阅使用真实目标"] = function()
  child.lua_func(function()
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
    assert(broken_state:set('value', 'first'), '失效符号链接的首次写入必须持久化')
    assert_eq(Fs.load_json(broken_state_target).entries['cross-process']['broken-alias'].value, 'first',
      '首次写入必须创建符号链接目标')
    assert(vim.wait(1000, function() return #broken_events == 1 end, 5),
      '通过失效符号链接订阅必须观察首次写入')
    assert_eq(broken_events[1].value, 'first', '失效符号链接订阅的新值')
    assert(broken_events[1].previous == nil, '失效符号链接订阅的前值')
    unsubscribe_broken()
  end)
end

T["失效链接含祖先链接与上级路径仍正确落盘"] = function()
  child.lua_func(function()
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
      '失效链接目标含祖先符号链接与上级路径时状态仍必须正确写入')
    assert_eq(Fs.load_json(nested_state_target).entries['cross-process']['nested-alias'].value, 'nested',
      '状态必须持久化到文件系统解析后的失效链接目标')
    assert(vim.fn.filereadable(vim.fs.joinpath(nested_state_alias_parent, 'target.json')) == 0,
      '状态不得写入仅字面归一化但语义错误的目标')
  end)
end

T["并发写入合并两进程字段且释放锁"] = function()
  child.lua_func(function()
    run_concurrent('set', {
      { mode = 'set', field = 'left', value = 'A' },
      { mode = 'set', field = 'right', value = 'B' },
    }, 100)

    local concurrent = Fs.load_json(process_path)
    assert_eq(concurrent.entries['cross-process'].panel.left, 'A',
      '并发写入不得丢失首个进程的更新')
    assert_eq(concurrent.entries['cross-process'].panel.right, 'B',
      '并发写入不得丢失第二个进程的更新')
    assert(vim.fn.filereadable(process_path .. '.lock') == 0,
      '并发写入不得残留锁')
  end)
end

T["符号链接别名与目标共享跨进程锁"] = function()
  child.lua_func(function()
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
      '别名并发写入不得丢失首个进程更新')
    assert_eq(symlink_data.entries['cross-process'].panel.right, 'B',
      '别名并发写入不得丢失第二个进程更新')
    assert(vim.fn.filereadable(symlink_target_path .. '.lock') == 0,
      '别名并发写入不得残留真实路径锁')
    assert(vim.fn.filereadable(symlink_alias_path .. '.lock') == 0,
      '别名并发写入不得创建别名路径锁')
  end)
end

T["并发恢复陈旧锁串行化且释放 reaper"] = function()
  child.lua_func(function()
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
      '并发恢复陈旧锁不得丢失首个进程更新')
    assert_eq(stale_concurrent.entries['cross-process'].panel.right, 'B',
      '并发恢复陈旧锁不得丢失第二个进程更新')
    assert(vim.fn.filereadable(stale_concurrent_lock) == 0,
      '并发恢复陈旧锁不得残留主锁')
    assert(vim.fn.filereadable(stale_concurrent_lock .. '.reap') == 0,
      '并发恢复陈旧锁不得残留 reaper')
  end)
end

T["CAS 区分 false 与缺失且并发只能一个赢家"] = function()
  child.lua_func(function()
    local cas_path = vim.fs.joinpath(root, 'cas.json')
    local cas = State.register('cross-process', 'panel', { path = cas_path })
    assert(cas:set('value', 'base'))
    assert(cas:set('flag', false))
    local false_mismatch, false_current = cas:compare_and_set('flag', nil, true)
    assert(not false_mismatch, 'CAS 必须区分已存 false 与缺失字段')
    assert(false_current == false, 'CAS 不匹配时必须返回已存 false')
    assert(cas:get('flag') == false, '失败的 CAS 必须保留已存 false')
    local false_updated, false_value, false_error = cas:compare_and_set('flag', false, true)
    assert(false_updated and false_value == true and not false_error,
      'CAS 必须能更新已存 false')
    assert(cas:set('flag', false))
    local false_removed, false_removed_value, false_removed_error = cas:compare_and_set('flag', false, nil)
    assert(false_removed and false_removed_value == nil and not false_removed_error,
      'CAS 必须能删除已存 false')
    assert(cas:get('flag', 'missing') == 'missing', 'CAS 删除必须移除 false 字段')
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
      '并发 CAS 必须恰好只有一个赢家')
    local winner = cas_results[1].updated and cas_results[1].current or cas_results[2].current
    local loser = cas_results[1].updated and cas_results[2] or cas_results[1]
    assert(loser.current == winner, 'CAS 败者必须观察到已提交赢家')
    local cas_data = Fs.load_json(cas_path)
    assert_eq(cas_data.entries['cross-process'].panel.value, winner,
      'CAS 败者不得覆盖赢家')
    assert(vim.fn.filereadable(cas_path .. '.lock') == 0, '并发 CAS 不得残留锁')
  end)
end

T["真实进程通知与幂等取消订阅"] = function()
  child.lua_func(function()
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
      '状态订阅进程未就绪')
    assert(subscribe_handle:set('value', 'after'))
    local subscriber_result = subscriber:wait()
    assert(subscriber_result.code == 0, '状态订阅进程失败：' .. subscriber_result.stderr)
    local observed = vim.json.decode(table.concat(vim.fn.readfile(subscribe_result), '\n'))
    assert_eq(observed.previous, 'before', '订阅前值')
    assert_eq(observed.value, 'after', '订阅必须收到另一进程写入的新值')

    local local_events = {}
    local unsubscribe = subscribe_handle:subscribe('value', function(value)
      local_events[#local_events + 1] = value
    end)
    assert(subscribe_handle:set('value', 'local-change'))
    assert(vim.wait(1000, function() return #local_events == 1 end, 5),
      '本地状态订阅未观察到文件变化')
    unsubscribe()
    unsubscribe()
    assert(subscribe_handle:set('value', 'after-unsubscribe'))
    vim.wait(100, function() return false end, 5)
    assert_eq(#local_events, 1, '取消订阅必须停止后续回调')
    local cancelled_events = 0
    local unsubscribe_pending = subscribe_handle:subscribe('value', function()
      cancelled_events = cancelled_events + 1
    end, { debounce_ms = 50 })
    assert(subscribe_handle:set('value', 'pending-unsubscribe'))
    vim.wait(10, function() return false end, 1)
    unsubscribe_pending()
    vim.wait(100, function() return false end, 5)
    assert_eq(cancelled_events, 0, '取消订阅必须压制待投递回调')
  end)
end

T["符号链接订阅观察真实路径写入"] = function()
  child.lua_func(function()
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
      '别名订阅未观察到真实路径写入')
    assert_eq(alias_events[1].previous, 'before', '别名订阅前值')
    assert_eq(alias_events[1].value, 'after', '别名订阅新值')
    unsubscribe_alias()
  end)
end

T["恢复陈旧锁后释放所有权"] = function()
  child.lua_func(function()
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
    assert(stale_handle:set('value', 'recovered'), '陈旧锁必须被回收')
    assert(vim.fn.filereadable(stale_lock_path) == 0, '回收的陈旧锁必须被释放')
  end)
end

T["恢复竞争保留替换后的活动锁主"] = function()
  child.lua_func(function()
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
    assert(reclaim_race_ok, '陈旧锁被替换不得让状态写入接口抛错')
    assert(replacement_injected, '未触发可控的陈旧锁替换竞态')
    assert(not reclaim_race_result, '活动的替换锁主不得被覆盖')
    assert(not replacement_deleted, '陈旧锁回收不得删除替换锁主')
    local replacement_owner = vim.json.decode(table.concat(vim.fn.readfile(reclaim_race_lock), '\n'))
    assert(replacement_owner.token == 'replacement-owner',
      '陈旧锁回收必须保留替换锁主')
  end)
end

T["活动 reaper 存在时禁止创建主锁"] = function()
  child.lua_func(function()
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
    assert(live_reaper_ok, '活动 reaper 不得让状态写入接口抛错')
    assert(not live_reaper_result, '活动 reaper 必须阻止主锁创建')
    assert(vim.fn.filereadable(live_reaper_lock) == 0,
      '被阻止的加锁不得绕过活动 reaper 创建主锁')
    assert(vim.fn.filereadable(live_reaper_gate) == 1,
      '活动 reaper 必须仍由创建者持有')
  end)
end

T["恢复隔离 reaper 不得覆盖更新的锁主"] = function()
  child.lua_func(function()
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
        -- B 先移动旧入口并发布替换锁主，再让当前竞争者移动刚检查过的路径
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
        -- B 被隔离期间，C 获取已经空出的路径
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
    assert(reaper_replace_ok, '新 reaper 替换不得让状态写入接口抛错')
    assert(not reaper_replace_result, '陈旧 reaper 恢复失败必须拒绝状态写入')
    assert(replace_injected, '未触发陈旧 reaper 替换竞态')
    assert(vim.fn.filereadable(reaper_replace_gate) == 1,
      '陈旧 reaper 恢复必须保留较新的 reaper')
    local replacement_reaper_owner = vim.json.decode(
      table.concat(vim.fn.readfile(reaper_replace_gate), '\n')
    )
    assert(replacement_reaper_owner.token == 'reaper-C',
      '陈旧 reaper 恢复不得覆盖较新的锁主')
    assert(replace_quarantine and vim.fn.filereadable(replace_quarantine) == 1,
      '陈旧 reaper 恢复失败必须保留隔离的锁主')
    local replace_notice_text = {}
    for _, notice in ipairs(replace_notices) do
      replace_notice_text[#replace_notice_text + 1] = tostring(notice.message)
    end
    assert(table.concat(replace_notice_text, '\n'):find('failed to restore stale state reaper', 1, true),
      '陈旧 reaper 恢复失败必须报告给调用方')
  end)
end

T["reaper 恢复失败立即拒绝主锁创建"] = function()
  child.lua_func(function()
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
    assert(reaper_failure_ok, 'reaper 恢复失败不得让状态写入接口抛错')
    assert(not reaper_failure_result, 'reaper 恢复失败必须拒绝状态写入')
    assert(failure_unlink_attempted and not failure_restore_attempted,
      '无覆盖链接恢复失败后必须停止 reaper 恢复')
    assert(vim.fn.filereadable(reaper_failure_lock) == 0,
      'reaper 恢复失败不得创建主锁')
    assert(vim.fn.filereadable(reaper_failure_gate) == 0,
      'reaper 恢复失败不得重建入口')
    assert(vim.fn.filereadable(failure_quarantine) == 1,
      'reaper 恢复失败必须保留隔离项')
  end)
end

T["释放隔离项暂时失败可重试且保持幂等"] = function()
  child.lua_func(function()
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
    assert(not first_release_ok and first_release_error, '首次释放失败必须报告')
    assert(second_release_ok, '后续释放必须重试删除自身隔离项')
    assert(vim.fn.filereadable(release_retry_lock.path) == 0,
      '释放重试成功必须移除主锁')
    assert(vim.fn.filereadable(release_quarantine) == 0,
      '释放重试成功必须移除隔离项')
    assert(release_retry_lock:release(), '重试成功后的释放必须仍然幂等')
  end)
end

T["所有权不匹配恢复失败为不可重复变更终态"] = function()
  child.lua_func(function()
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
      '所有权不匹配必须保持释放失败')
    assert(mismatch_first_error == mismatch_second_error,
      '所有权不匹配的恢复失败在重试时必须保持相同错误')
    assert(mismatch_restore_attempts == 1,
      '终态所有权不匹配不得反复修改隔离项')
    assert(vim.fn.filereadable(release_mismatch_lock.path) == 0,
      '所有权恢复失败不得创建替换主锁')
    assert(vim.fn.filereadable(mismatch_quarantine) == 1,
      '所有权恢复失败必须保留非自身锁主的隔离项')
  end)
end

T["非法陈旧锁与活动锁超时不抛异常也不删除"] = function()
  child.lua_func(function()
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
    assert(invalid_stale_ok, '非法陈旧锁不得让状态写入接口抛错')
    assert(not invalid_stale_result, '非法陈旧锁必须让 set 返回 false')
    assert(vim.fn.isdirectory(invalid_stale_lock_path) == 1,
      '无法回收的非法陈旧锁必须保持原样')

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
    assert(not timeout_handle:set('value', 'blocked'), '活动锁必须超时而不是被回收')
    assert(vim.fn.filereadable(timeout_lock_path) == 1, '超时后的锁必须仍由原主持有')
    assert(vim.uv.fs_unlink(timeout_lock_path))
  end)
end

return T
