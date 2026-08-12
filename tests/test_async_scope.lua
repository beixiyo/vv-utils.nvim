-- 异步请求作用域行为回归
-- 运行：nvim --headless -u NONE -l tests/test_async_scope.lua

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
vim.opt.runtimepath:prepend(root)

local Async = require('vv-utils.async')

do
  local ok = pcall(function() Async.scope(false) end)
  assert(not ok, 'false is not a scope options object')
end

local function queue()
  local callbacks = {}
  return {
    start = function(callback)
      callbacks[#callbacks + 1] = callback
      return #callbacks
    end,
    resolve = function(index, value)
      callbacks[index](value)
    end,
  }
end

do
  local producer = queue()
  local scope = Async.scope()
  local result

  local request_a = scope:begin()
  producer.start(function(value)
    local current = request_a:finish()
    if current then result = value end
  end)

  local request_b = scope:begin()
  producer.start(function(value)
    local current = request_b:finish()
    if current then result = value end
  end)

  producer.resolve(2, 'B')
  producer.resolve(1, 'A')
  assert(result == 'B', 'a slower superseded request must not overwrite the latest result')
  assert(request_a:reason() == 'superseded')
end

do
  local scope = Async.scope()
  local old_lifecycle = scope:begin()
  scope:invalidate()
  local new_lifecycle = scope:begin()

  assert(not old_lifecycle:is_current(), 'owner invalidation must reject the old lifecycle')
  assert(new_lifecycle:is_current(), 'the scope must remain reusable after invalidation')
  assert(old_lifecycle:finish() == false)
  assert(old_lifecycle:reason() == 'owner-invalidated')
  assert(new_lifecycle:finish() == true)
end

do
  local scope = Async.scope({ cancel_previous = true })
  local cancelled = 0
  local disposed = 0
  local old = scope:begin({
    cancel = function() cancelled = cancelled + 1 end,
    dispose = function() disposed = disposed + 1 end,
  })
  local new = scope:begin()

  assert(cancelled == 1, 'superseding must invoke physical cancellation when configured')
  assert(disposed == 1, 'superseding must dispose caller-owned resources')
  old:cancel()
  old:dispose()
  assert(cancelled == 1 and disposed == 1, 'request cleanup must be idempotent')
  assert(new:is_current(), 'old cleanup must not unlink the newer request')
  assert(new:finish())
end

do
  local scope = Async.scope()
  local cancelled = 0
  local disposed = 0
  local request = scope:begin()

  scope:cancel()
  request:set_cancel(function() cancelled = cancelled + 1 end)
  request:set_disposer(function() disposed = disposed + 1 end)

  assert(cancelled == 1, 'a late cancel handle must run after cancellation wins synchronously')
  assert(disposed == 1, 'a late disposer must run after termination wins synchronously')
  assert(not request:is_current(), 'queued callbacks must remain stale after cancellation')
end

do
  local scope = Async.scope()
  local published = false
  local callback_ran = false
  local request = scope:begin()
  vim.schedule(function()
    callback_ran = true
    if request:finish() then published = true end
  end)

  scope:cancel()
  assert(vim.wait(100, function() return callback_ran end, 10),
    'the queued callback fixture must actually execute')
  assert(not published, 'a callback already queued by vim.schedule must remain logically cancelled')
end

do
  local scope = Async.scope()
  local request_b
  local request_a = scope:begin({
    dispose = function()
      request_b = scope:begin()
      assert(request_b:finish(), 'the reentrant request should finish as the latest request')
    end,
  })

  assert(not request_a:finish(),
    'finish must revoke publication when its disposer synchronously completes a newer request')
end

do
  local scope = Async.scope({ cancel_previous = true })
  local cancelled = 0
  local request_a = scope:begin({ cancel = function() cancelled = cancelled + 1 end })

  local ok = pcall(function() scope:begin({ cancel = true }) end)
  assert(not ok, 'an invalid cancel option must fail')
  assert(request_a:is_current() and cancelled == 0,
    'invalid request options must not mutate or cancel the current request')

  ok = pcall(function() scope:begin(false) end)
  assert(not ok and request_a:is_current(), 'false is not a request options object')
  request_a:finish()
end

do
  local scope = Async.scope()
  local latest = scope:begin({ key = 'mixed', mode = 'latest' })
  local ok = pcall(function()
    scope:begin({ key = 'mixed', mode = 'parallel' })
  end)

  assert(not ok, 'one active lane must not mix latest and parallel modes')
  assert(latest:is_current() and latest:finish(),
    'a rejected mixed-mode begin must not mutate the existing lane')

  local parallel = scope:begin({ key = 'mixed', mode = 'parallel' })
  assert(parallel:is_current() and parallel:finish(),
    'a fully released key may be reused with a different lane mode')
end

do
  local scope = Async.scope()
  local ok = pcall(function() scope:begin({ mode = false }) end)
  assert(not ok, 'mode=false must not be normalized to latest')

  local current = scope:begin()
  assert(current:is_current() and current:finish(),
    'invalid mode validation must leave the scope reusable and unmodified')
end

do
  local scope = Async.scope()
  local request_a = scope:begin({ key = 'a' })
  local request_b = scope:begin({ key = 'b' })
  assert(request_a:is_current() and request_b:is_current(),
    'latest-wins requests in different keys must remain independently current')
  request_a:finish()
  request_b:finish()
end

do
  local scope = Async.scope()
  local disposed = 0
  local original_notify = vim.notify
  local notification
  vim.notify = function(message) notification = message end
  local bad_error = setmetatable({}, {
    __tostring = function() error('cannot stringify cleanup error') end,
  })
  local request = scope:begin({
    cancel = function() error(bad_error) end,
    dispose = function() disposed = disposed + 1 end,
  })

  local ok = pcall(function() request:cancel() end)
  vim.notify = original_notify
  assert(ok, 'cleanup error reporting must not escape request cancellation')
  assert(disposed == 1, 'a failing cancel callback must not skip the disposer')
  assert(notification and notification:find('could not be formatted', 1, true),
    'an unprintable cleanup error must still produce a safe diagnostic')
end

do
  local scope = Async.scope()
  local cancelled = 0
  local disposed = 0
  local request = scope:begin()

  local function start(callback)
    callback('sync')
    return function() cancelled = cancelled + 1 end,
      function() disposed = disposed + 1 end
  end

  local cancel, dispose = start(function()
    assert(request:finish(), 'a synchronous completion must still be current')
  end)
  request:set_cancel(cancel)
  request:set_disposer(dispose)

  assert(cancelled == 0, 'finish must not cancel an already completed producer')
  assert(disposed == 1, 'a disposer acquired after synchronous completion must run immediately')
end

do
  local scope = Async.scope()
  local first = scope:begin({ mode = 'parallel' })
  local second = scope:begin({ mode = 'parallel' })
  assert(first:is_current() and second:is_current(), 'parallel requests must remain independently valid')
  assert(first:finish() and second:finish())
end

do
  local scope = Async.scope()
  local cancelled = 0
  local request = scope:begin({ cancel = function() cancelled = cancelled + 1 end })
  request:invalidate()
  scope:cancel()

  assert(cancelled == 1, 'owner cancellation must still reach logically invalidated resources')
end

-- Owner teardown order is unspecified. Whichever request is cancelled first completes
-- its successor; the outer snapshot must still terminate the remaining request.
for _, teardown in ipairs({ 'cancel', 'dispose' }) do
  local scope = Async.scope()
  local cancelled = { a = 0, b = 0, c = 0 }
  local requests = {
    a = scope:begin({ key = 'a' }),
    b = scope:begin({ key = 'b' }),
    c = scope:begin({ key = 'c' }),
  }
  local successor = { a = 'b', b = 'c', c = 'a' }
  for name, request in pairs(requests) do
    request:set_cancel(function()
      cancelled[name] = cancelled[name] + 1
      requests[successor[name]]:finish()
    end)
  end

  local ok = pcall(function() scope[teardown](scope) end)
  assert(ok, teardown .. ' must not lose a later snapshot entry after synchronous reentry')
  assert(cancelled.a + cancelled.b + cancelled.c == 2,
    teardown .. ' must physically cancel every request not synchronously finished by another callback')
  local owner_reason = teardown == 'dispose' and 'owner-disposed' or 'cancelled'
  local finished = 0
  for _, request in pairs(requests) do
    if request:reason() == 'finished' then
      finished = finished + 1
    else
      assert(request:reason() == owner_reason, teardown .. ' must preserve owner terminal reason')
    end
  end
  assert(finished == 1, teardown .. ' must finish exactly one request synchronously')
end

do
  local retained = setmetatable({}, { __mode = 'v' })
  local function create_terminal_cycle()
    local scope = Async.scope()
    local request
    request = scope:begin({ dispose = function() assert(request) end })
    request:finish()
    retained.request = request
    retained.scope = scope
  end

  create_terminal_cycle()
  for _ = 1, 5 do collectgarbage('collect') end
  assert(retained.request == nil and retained.scope == nil,
    'a terminal callback cycle must not retain its request or scope')
end

do
  local scope = Async.scope()
  local request = scope:begin()
  scope:dispose()

  assert(scope:is_disposed())
  assert(not request:is_current())
  local ok = pcall(function() scope:begin() end)
  assert(not ok, 'a disposed scope must reject new requests')
end

print('vv-utils async scope: PASS')
