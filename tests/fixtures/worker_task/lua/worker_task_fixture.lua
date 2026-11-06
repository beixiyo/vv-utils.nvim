local dependency = require('worker_task_dependency')

return function(input, index)
  assert(vim.is_thread(), '必须在真实 worker 线程执行')
  assert(_G.worker_task_main_only == nil, '不能捕获主线程全局')
  local file = assert(io.open(input.root .. '/started-' .. index, 'w'))
  file:write('started')
  file:close()
  local deadline = vim.uv.hrtime() + 5000000000
  while true do
    local gate = io.open(input.root .. '/release-' .. index, 'r')
    if gate then
      gate:close()
      break
    end
    assert(vim.uv.hrtime() < deadline, '测试门闩未释放')
    vim.uv.sleep(1)
  end
  if input.fail then
    error('预期 worker 失败')
  end
  if input.bad_result then
    return function() end
  end
  return dependency(input)
end
