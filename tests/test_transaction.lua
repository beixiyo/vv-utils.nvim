-- 通用事务的顺序、异步 callback、补偿锁定、撤回与 fs 委托测试
-- 运行：nvim --headless --clean -l tests/test_transaction.lua

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.runtimepath:prepend(repo)

local Transaction = require('vv-utils.transaction')

local passed = 0
local failed = 0

local function test(name, fn)
  local ok, error = pcall(fn)
  if ok then
    passed = passed + 1
    print('[PASS] ' .. name)
  else
    failed = failed + 1
    print('[FAIL] ' .. name .. ': ' .. tostring(error))
  end
end

local function assert_eq(actual, expected)
  assert(actual == expected, string.format('expected %q, got %q', tostring(expected), tostring(actual)))
end

test('同步事务按顺序预检、应用、逆序补偿并保留一层 undo', function()
  local events = {}
  local state = { a = 'old-a', b = 'old-b' }
  local transaction = Transaction.new({
    operations = {
      {
        name = 'a',
        validate = function() events[#events + 1] = 'validate-a' end,
        apply = function(context)
          assert(context.marker)
          events[#events + 1] = 'apply-a'
          state.a = 'new-a'
        end,
        compensate = function()
          events[#events + 1] = 'compensate-a'
          state.a = 'old-a'
        end,
      },
      {
        name = 'b',
        validate = function() events[#events + 1] = 'validate-b' end,
        apply = function()
          events[#events + 1] = 'apply-b'
          state.b = 'new-b'
        end,
        compensate = function()
          events[#events + 1] = 'compensate-b'
          state.b = 'old-b'
        end,
      },
    },
  })

  local ok, error, result = transaction:apply({ marker = true })
  assert(ok, error)
  assert(result.undoable)
  assert(transaction:can_undo())
  assert_eq(table.concat(events, ','), 'validate-a,validate-b,apply-a,apply-b')

  local undo_ok, undo_error, undo_result = transaction:undo()
  assert(undo_ok, undo_error)
  assert_eq(undo_result.count, 2)
  assert_eq(state.a, 'old-a')
  assert_eq(state.b, 'old-b')
  assert_eq(table.concat(events, ','),
    'validate-a,validate-b,apply-a,apply-b,validate-a,validate-b,compensate-b,compensate-a')
  assert(not transaction:can_undo())
end)

test('预检失败时不触发任何 apply', function()
  local applies = 0
  local transaction = Transaction.new({
    operations = {
      {
        validate = function() return true end,
        apply = function() applies = applies + 1 end,
        compensate = function() end,
      },
      {
        validate = function() return false, 'stale operation' end,
        apply = function() applies = applies + 1 end,
        compensate = function() end,
      },
    },
  })

  local ok, error, result = transaction:apply()
  assert_eq(ok, false)
  assert(error:find('stale operation', 1, true), error)
  assert_eq(applies, 0)
  assert_eq(result.touched, 0)
  assert(not transaction:is_locked())
end)

test('异步失败按逆序补偿、busy 可见且 callback 只完成一次', function()
  local callbacks = {}
  local events = {}
  local state = { a = 'old-a', b = 'old-b' }
  local callback_count = 0
  local final_ok
  local final_error
  local transaction = Transaction.new({
    operations = {
      {
        name = 'a',
        async = true,
        validate = function(_, done) done(true) end,
        apply = function(_, done)
          callbacks.apply_a = done
          return function() end
        end,
        compensate = function(_, done)
          callbacks.compensate_a = done
        end,
      },
      {
        name = 'b',
        async = true,
        validate = function(_, done) done(true) end,
        apply = function(_, done)
          callbacks.apply_b = done
        end,
        compensate = function(_, done)
          callbacks.compensate_b = done
        end,
      },
    },
  })

  local pending = transaction:apply(function(ok, error)
    callback_count = callback_count + 1
    final_ok = ok
    final_error = error
  end)
  assert_eq(pending, nil)
  assert(transaction:is_busy())

  local busy_ok, busy_error = transaction:apply(function() end)
  assert_eq(busy_ok, false)
  assert_eq(busy_error, Transaction.BUSY_ERROR)

  state.a = 'new-a'
  events[#events + 1] = 'apply-a'
  callbacks.apply_a(true)
  callbacks.apply_a(false, 'late apply callback')

  state.b = 'new-b'
  events[#events + 1] = 'apply-b'
  callbacks.apply_b(false, 'apply-b failed')
  callbacks.apply_b(true)

  state.b = 'old-b'
  events[#events + 1] = 'compensate-b'
  callbacks.compensate_b(true)
  callbacks.compensate_b(false, 'late compensation callback')

  state.a = 'old-a'
  events[#events + 1] = 'compensate-a'
  callbacks.compensate_a(true)

  assert_eq(callback_count, 1)
  assert_eq(final_ok, false)
  assert(final_error:find('apply%-b failed') or final_error:find('apply-b failed', 1, true), final_error)
  assert_eq(table.concat(events, ','), 'apply-a,apply-b,compensate-b,compensate-a')
  assert_eq(state.a, 'old-a')
  assert_eq(state.b, 'old-b')
  assert(not transaction:is_busy())
  assert(not transaction:is_locked())
end)

test('显式 callback operation 返回 vim.system handle 时保持 pending', function()
  local callback_count = 0
  local final_ok
  local final_error
  local transaction = Transaction.new({
    operations = {
      {
        name = 'process-handle',
        callback = true,
        validate = function(_, done) done(true) end,
        apply = function(_, done)
          local process = vim.system({ 'sh', '-c', 'sleep 0.01; exit 0' }, {}, function(result)
            done(result.code == 0, result.stderr ~= '' and result.stderr or nil)
          end)
          assert(process)
          return process
        end,
        compensate = function(_, done) done(true) end,
      },
    },
  })

  local immediate = transaction:apply(function(ok, error)
    callback_count = callback_count + 1
    final_ok = ok
    final_error = error
  end)
  assert_eq(immediate, nil)
  assert(transaction:is_busy())
  assert(vim.wait(1000, function() return callback_count == 1 end, 10), 'process callback timeout')
  assert(final_ok, final_error)
  assert(not transaction:is_busy())
  assert(transaction:can_undo())
  assert(transaction:undo())
end)

test('未显式标记的二参数 operation 按同步返回处理', function()
  local late_callback
  local transaction = Transaction.new({
    operations = {
      {
        apply = function(_, done)
          late_callback = done
          return true
        end,
        compensate = function() end,
      },
    },
  })

  local ok, error = transaction:apply()
  assert(ok, error)
  assert(not transaction:is_busy())
  assert(transaction:can_undo())
  late_callback(false, 'late callback')
  assert(transaction:can_undo())
  assert(transaction:undo())
end)

test('补偿失败后锁定实例并拒绝后续执行', function()
  local transaction = Transaction.new({
    operations = {
      {
        name = 'first',
        apply = function() end,
        compensate = function() end,
      },
      {
        name = 'second',
        apply = function() return false, 'apply failed' end,
        compensate = function() return false, 'compensation failed' end,
      },
    },
  })

  local ok, error = transaction:apply()
  assert_eq(ok, false)
  assert(error:find('compensation failed', 1, true), error)
  assert(transaction:is_locked())

  local retry_ok, retry_error = transaction:apply()
  assert_eq(retry_ok, false)
  assert_eq(retry_error, Transaction.LOCKED_ERROR)
end)

test('未触碰的失败 operation 不参与补偿和 undo 恢复', function()
  local applied = 0
  local compensated = 0
  local transaction = Transaction.new({
    operations = {
      {
        apply = function() applied = applied + 1 end,
        compensate = function() compensated = compensated + 1 end,
      },
      {
        apply = function()
          return false, Transaction.failure('failed before write', false)
        end,
        compensate = function() error('must not compensate untouched operation') end,
      },
    },
  })

  local ok, error, result = transaction:apply()
  assert_eq(ok, false)
  assert(error:find('failed before write', 1, true), error)
  assert_eq(result.touched, 1)
  assert_eq(applied, 1)
  assert_eq(compensated, 1)
  assert(not transaction:is_locked())
end)

test('没有补偿策略的成功事务不可 undo', function()
  local transaction = Transaction.new({
    operations = {
      { apply = function() end },
    },
  })

  local ok, error, result = transaction:apply()
  assert(ok, error)
  assert(not result.undoable)
  assert(not transaction:can_undo())
  assert_eq(transaction:undo(), false)
end)

print(string.format('总计: %d 通过, %d 失败', passed, failed))
if failed > 0 then vim.cmd('cquit 1') end
