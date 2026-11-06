-- 后台任务控制器：有界动态派发、按索引聚合、通知与逻辑终结；实际 work 完成后释放资源
local M = {}

-- uv 序列化的仅为固定入口；业务函数在池线程中 require，不捕获主线程状态
local function execute(module, lua_path, c_path, encoded, index)
  local ok, result = xpcall(function()
    package.path, package.cpath = lua_path, c_path
    local worker = require(module)
    local value = worker(vim.mpack.decode(encoded), index)
    if value == nil then
      value = vim.NIL
    end
    return vim.mpack.encode(value)
  end, function(err) return debug.traceback(tostring(err), 2) end)
  return ok, result
end

local function traceback(err)
  return debug.traceback(tostring(err), 2)
end

local function search_paths()
  local paths = {}
  for _, root in ipairs(vim.api.nvim_list_runtime_paths()) do
    paths[#paths + 1] = root .. '/lua/?.lua'
    paths[#paths + 1] = root .. '/lua/?/init.lua'
  end
  paths[#paths + 1] = package.path
  return table.concat(paths, ';'), package.cpath
end

---@param opts vv-utils.async.WorkerTaskOpts
---@return vv-utils.async.WorkerTask
function M.new(opts)
  local total, concurrency = opts.total, opts.concurrency
  if concurrency == nil then
    concurrency = 4
  end
  assert(type(total) == 'number' and total >= 0 and total < math.huge and total % 1 == 0,
    'worker_task.total must be a non-negative integer')
  assert(type(concurrency) == 'number' and concurrency >= 1 and concurrency < math.huge and concurrency % 1 == 0,
    'worker_task.concurrency must be a positive integer')
  assert(type(opts.worker) == 'string' and opts.worker ~= '', 'worker_task.worker must be a module name')
  assert(type(opts.input) == 'function', 'worker_task.input must be a function')
  assert(opts.on_done == nil or type(opts.on_done) == 'function', 'worker_task.on_done must be a function')

  local worker, input, on_done = opts.worker, opts.input, opts.on_done
  local state, next_index, completed = 'idle', 1, 0
  local results = {}
  local listeners = { item = {}, progress = {} }
  local outcome, lua_path, c_path
  local task = {}

  local function is_running()
    return state == 'running'
  end

  local function is_terminal()
    return state ~= 'idle' and state ~= 'running'
  end

  local function finish(final_state, err)
    if is_terminal() then
      return
    end

    state = final_state
    outcome = { state = state, results = results, completed = completed, total = total, error = err }
    input = nil

    for _, subscriptions in pairs(listeners) do
      for _, subscription in ipairs(subscriptions) do
        subscription.callback = nil
      end
    end

    listeners = { item = {}, progress = {} }
    local callback = on_done
    on_done = nil

    if callback then
      -- 完成回调异常遵循普通 scheduled callback；不改写终态、不二次通知
      vim.schedule(function() callback(outcome) end)
    end
  end

  local function fail(err)
    finish('failed', tostring(err))
  end

  local function notify(event, data)
    local subscriptions = listeners[event]
    local count = #subscriptions

    for i = 1, count do
      if not is_running() then
        return
      end
      local callback = subscriptions[i].callback
      if callback then
        callback(data)
      end
    end
  end

  local dispatch
  local function receive(slot, ok, payload)
    if not is_running() then
      slot.work = nil
      return
    end

    local index = slot.index
    local success, err = xpcall(function()
      assert(ok, payload)
      local value = vim.mpack.decode(payload)
      results[index] = value
      completed = completed + 1
      notify('item', { index = index, value = value, completed = completed, total = total })
      if not is_running() then
        return
      end
      notify('progress', { completed = completed, total = total, progress = completed / total })
      if is_running() and completed == total then
        finish('completed')
      end
    end, traceback)

    if not success then
      fail(('worker_task item %d: %s'):format(index, err))
    end

    if is_running() and next_index <= total then
      dispatch(slot)
    else
      slot.work = nil
    end
  end

  dispatch = function(slot)
    local index = next_index
    next_index = next_index + 1
    slot.index = index

    local ok, err = xpcall(function()
      local value = input(index)
      if not is_running() then
        -- 补位时旧 work 已完成，新 work 尚未入队；取消不能留下旧 context 引用环
        slot.work = nil
        return
      end

      local encoded = vim.mpack.encode(value)
      if not slot.work then
        slot.work = vim.uv.new_work(execute, vim.schedule_wrap(function(success, payload)
          receive(slot, success, payload)
        end))
      end

      local queued, queue_error = slot.work:queue(worker, lua_path, c_path, encoded, index)
      assert(queued, queue_error)
    end, traceback)

    if not ok then
      slot.work = nil
      fail(('worker_task input/queue %d: %s'):format(index, err))
    end
  end

  function task:get_state()
    return state
  end

  function task:get_result()
    return outcome
  end

  function task:start()
    if state ~= 'idle' then
      return
    end
    state = 'running'

    vim.schedule(function()
      if not is_running() then
        return
      end

      local ok, err = xpcall(function()
        lua_path, c_path = search_paths()
        if total == 0 then
          notify('progress', { completed = 0, total = 0, progress = 1 })
          if is_running() then
            finish('completed')
          end
          return
        end

        for _ = 1, math.min(total, concurrency) do
          if not is_running() then
            break
          end
          dispatch({})
        end
      end, traceback)

      if not ok then
        fail(err)
      end
    end)
  end

  function task:cancel()
    finish('cancelled', 'worker_task cancelled')
  end

  function task:on(event, callback)
    assert(listeners[event], 'worker_task event must be item or progress')
    assert(type(callback) == 'function', 'worker_task listener must be a function')

    if is_terminal() then
      return function() end
    end

    local subscription = { callback = callback }
    table.insert(listeners[event], subscription)

    return function()
      subscription.callback = nil
    end
  end

  return task
end

return M
