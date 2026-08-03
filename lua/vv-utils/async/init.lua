-- 异步请求作用域
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

local Scope = require('vv-utils.async.scope')

local M = {}

---创建不依赖插件状态或 UI 策略的异步请求作用域
---@param opts? vv-utils.async.ScopeOpts
---@return vv-utils.async.Scope
function M.scope(opts)
  return Scope.new(opts)
end

return M
