-- test_state.lua 的跨 Neovim 进程并发夹具

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.runtimepath:prepend(repo)

local path = assert(vim.env.VV_STATE_TEST_PATH)
local mode = assert(vim.env.VV_STATE_TEST_MODE)
local field = vim.env.VV_STATE_TEST_FIELD
local value = vim.env.VV_STATE_TEST_VALUE
local start_path = vim.env.VV_STATE_TEST_START
local ready_path = vim.env.VV_STATE_TEST_READY
local result_path = vim.env.VV_STATE_TEST_RESULT

local Fs = require('vv-utils.fs')
local delay_ms = tonumber(vim.env.VV_STATE_TEST_DELAY_MS or '') or 0
if delay_ms > 0 then
  local save_json = Fs.save_json
  Fs.save_json = function(...)
    vim.uv.sleep(delay_ms)
    return save_json(...)
  end
end

local state = require('vv-utils.state').register('cross-process', 'panel', {
  path = path,
})

local function synchronize()
  assert(start_path and ready_path)
  assert(vim.fn.writefile({ 'ready' }, ready_path) == 0)
  assert(vim.wait(10000, function()
    return vim.fn.filereadable(start_path) == 1
  end, 5), '并发状态 fixture 等待同步屏障超时')
end

if mode == 'set' then
  synchronize()
  assert(field and value)
  assert(state:set(field, value))
elseif mode == 'cas' then
  synchronize()
  assert(value)
  local updated, current, error_message = state:compare_and_set('value', 'base', value)
  assert(result_path)
  assert(vim.fn.writefile({ vim.json.encode({
    updated = updated,
    current = current,
    error_message = error_message,
  }) }, result_path) == 0)
  assert(not error_message, error_message)
elseif mode == 'write' then
  assert(state:set('width', 57))
elseif mode == 'read' then
  assert(state:get('width') == 57, '新 Neovim 进程未恢复持久宽度 57')
elseif mode == 'subscribe' then
  assert(ready_path and result_path)
  local unsubscribe = state:subscribe('value', function(next_value, previous)
    assert(vim.fn.writefile({ vim.json.encode({
      value = next_value,
      previous = previous,
    }) }, result_path) == 0)
  end)
  assert(vim.fn.writefile({ 'ready' }, ready_path) == 0)
  assert(vim.wait(10000, function()
    return vim.fn.filereadable(result_path) == 1
  end, 5), '状态订阅等待另一进程写入超时')
  unsubscribe()
else
  error('unknown state process fixture mode: ' .. mode)
end
