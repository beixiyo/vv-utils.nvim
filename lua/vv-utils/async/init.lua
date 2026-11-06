-- 异步请求作用域、批处理与调度合并
-- 公共入口与共享 API 类型

---@alias vv-utils.async.RequestMode 'latest'|'parallel'
---@alias vv-utils.async.RequestKey string|integer
---@alias vv-utils.async.RequestReason 'superseded'|'invalidated'|'owner-invalidated'|'cancelled'|'disposed'|'finished'|'owner-disposed'

---@class vv-utils.async.ScopeOpts
---@field cancel_previous? boolean 是否物理取消被后续请求取代的 latest 请求 @default false

---@class vv-utils.async.RequestOpts
---@field key? vv-utils.async.RequestKey latest-wins 通道 @default 'default'
---@field mode? vv-utils.async.RequestMode 同一 key 的在途请求必须使用相同通道模式 @default 'latest'
---@field cancel_previous? boolean 覆盖 scope 为本次请求设置的默认值 @default 继承 scope 配置
---@field cancel? fun() 调用方拥有的物理取消回调 @default nil
---@field dispose? fun() 调用方拥有的幂等资源释放回调 @default nil

---@class vv-utils.async.BatchOpts
---@field items any[] 待处理项，按数组顺序执行
---@field worker fun(item: any, index: integer): string? 单项工作；返回 err 字符串记为该项失败并继续，抛错同样记入 errors 并继续
---@field budget_ms? number 单片时间预算（毫秒），不可抢占单项，实际耗时可超出 @default 8
---@field budget_items? integer 单片最多处理的项数 @default 20
---@field is_valid? fun(): boolean 每项执行前检查；返回 false 停止排片（常绑定 request:is_current） @default nil
---@field on_progress? fun(done: integer, total: integer) 每片结束后调用 @default nil
---@field on_done? fun(result: vv-utils.async.BatchResult) 终结回调；cancel() 后不调用 @default nil

---@class vv-utils.async.BatchResult
---@field done integer 实际处理项数
---@field total integer 总项数
---@field aborted boolean 因 is_valid 失效或无法创建续片 timer 而提前结束
---@field errors { item: any, index: integer, err: string }[] 单项失败记录

---@class vv-utils.async.BatchHandle
---@field cancel fun() 幂等；停止排片且不触发 on_done

local Scope = require('vv-utils.async.scope')
local Batch = require('vv-utils.async.batch')
local Coalesce = require('vv-utils.async.coalesce')

local M = {}

---创建不依赖插件状态或 UI 策略的异步请求作用域
---@param opts? vv-utils.async.ScopeOpts
---@return vv-utils.async.Scope
function M.scope(opts)
  return Scope.new(opts)
end

---创建按时间预算分片执行的批处理器；批量重活经 uv timer 让出事件循环
---@param opts vv-utils.async.BatchOpts
---@return vv-utils.async.BatchHandle
function M.batch(opts)
  return Batch.run(opts)
end

---创建可释放的调度合并队列；不等待 run 启动的异步任务，也不提供时间片出让
---@param opts vv-utils.async.CoalesceOpts
---@return vv-utils.async.CoalesceHandle
function M.coalesce(opts)
  return Coalesce.new(opts)
end

---@class vv-utils.async.CoalesceOpts
---@field run fun() 调度时读取最新状态并执行；异常按普通 scheduled callback 传播

---@alias vv-utils.async.CoalesceState 'idle'|'pending'|'disposed'

---@class vv-utils.async.CoalesceHandle
---@field get_state fun(self: vv-utils.async.CoalesceHandle): vv-utils.async.CoalesceState 调度状态；不表示 run 或异步任务的执行状态
---@field request fun(self: vv-utils.async.CoalesceHandle) 合并尚未执行的请求；dispose 后无效
---@field dispose fun(self: vv-utils.async.CoalesceHandle) 幂等且永久关闭，已排队回调失效；不取消 run 已启动的异步任务

---创建一次性后台任务控制器；start 后才派发到共享 libuv 线程池
---@param opts vv-utils.async.WorkerTaskOpts
---@return vv-utils.async.WorkerTask
function M.worker_task(opts)
  return require('vv-utils.async.worker_task').new(opts)
end

---@alias vv-utils.async.WorkerTaskState 'idle'|'running'|'completed'|'failed'|'cancelled'

---@class vv-utils.async.WorkerTaskOpts
---@field total integer 非负输入项数，索引从 1 开始
---@field worker string 独立纯 Lua 模块名，返回 fun(input: any, index: integer): any
---@field concurrency? integer 正整数，仅限制本控制器在途项数，不是独占线程数 @default 4
---@field input fun(index: integer): any 主线程同步准备单项 mpack 可编码数据；在领取时调用
---@field on_done? fun(outcome: vv-utils.async.WorkerTaskResult) 所有终态 scheduled 通知一次；异常按普通调度回调报告

---@class vv-utils.async.WorkerTaskItem
---@field index integer 1-based 输入索引
---@field value any nil 返回值规范为 vim.NIL
---@field completed integer 已记录的成功项数
---@field total integer 输入总数

---@class vv-utils.async.WorkerTaskProgress
---@field completed integer 已记录的成功项数
---@field total integer 输入总数
---@field progress number completed / total；空任务为 1

---@class vv-utils.async.WorkerTaskResult
---@field state 'completed'|'failed'|'cancelled'
---@field results table<integer, any> 按输入索引存储；未完成槽为 nil；调用方只读
---@field completed integer 已记录的成功项数；失败/取消时 results 可稀疏，不用 # 计数
---@field total integer 输入总数
---@field error? string 失败诊断或取消原因；成功为 nil

---@class vv-utils.async.WorkerTask
---@field start fun(self: vv-utils.async.WorkerTask) 幂等；不重启终态实例
---@field cancel fun(self: vv-utils.async.WorkerTask) 幂等；停止派发/发布，不中断已排队的 work
---@field get_state fun(self: vv-utils.async.WorkerTask): vv-utils.async.WorkerTaskState
---@field get_result fun(self: vv-utils.async.WorkerTask): vv-utils.async.WorkerTaskResult? 终态只读快照；不深拷贝，不重放回调
---@field on fun(self: vv-utils.async.WorkerTask, event: 'item'|'progress', listener: fun(event: vv-utils.async.WorkerTaskItem|vv-utils.async.WorkerTaskProgress)): fun() 同步订阅，返回幂等退订；终态释放所有监听

return M
