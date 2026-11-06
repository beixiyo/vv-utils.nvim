-- 合并尚未执行的调度请求；owner 释放后让排队回调失效，不承担时间分片或异步任务取消
local M = {}

---创建可永久释放的刷新队列；回调执行时由调用方读取最新状态
---@param opts vv-utils.async.CoalesceOpts
---@return vv-utils.async.CoalesceHandle
function M.new(opts)
  local run = opts.run
  local pending, disposed = false, false

  local handle = {}

  ---排入一次刷新；执行前的重复请求合并，不增加定时延迟
  function handle:request()
    if pending or disposed then
      return
    end

    pending = true
    vim.schedule(function()
      -- 先释放 pending，允许回调重入请求；抛错也不会阻断后续调度
      pending = false
      if not disposed then
        run()
      end
    end)
  end

  ---查询调度状态，不代表 run 或其启动的异步任务是否仍在执行
  ---@return vv-utils.async.CoalesceState
  function handle:get_state()
    if disposed then
      return 'disposed'
    end
    return pending and 'pending' or 'idle'
  end

  ---永久关闭队列，已排入的回调失效；重复调用无副作用
  function handle:dispose()
    disposed = true
  end

  return handle
end

return M
