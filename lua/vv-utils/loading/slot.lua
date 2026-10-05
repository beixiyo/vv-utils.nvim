-- vv-utils.loading.slot — 同一 UI 位置的多个并发请求共用一个 loading 显示
--
-- 引用计数：0→1 时调用 create() 建 handle，归零时 stop。文案取最近一次仍在途的 acquire；
-- 旧请求 release 不会停掉新请求的显示（latest-wins 场景旧请求被顶替后仍会终结）
-- 只有 acquire 会（重）建 handle：handle 因 owner 失效（如 buffer wipe）自动停止后，release 只递减计数、
-- 不重建（宿主资源已失效，重建无意义且 create 可能抛错），因此 release 永不抛错，可放心用作 disposer；
-- 之后的新 acquire 仍会调用 create() 重建显示

local M = {}

-- 字段定义见文件底部（LuaLS 需要这一行把方法表绑定到类上）
---@class vv-utils.loading.Slot
local Slot = {}
Slot.__index = Slot

---@param create fun(): vv-utils.loading.Handle
---@return vv-utils.loading.Slot
function M.new(create)
  return setmetatable({ _create = create, _tokens = {} }, Slot)
end

--- 让显示与在途登记一致：无登记则停止；有登记则把文案同步为栈顶请求
---@private
---@param allow_create boolean 无可用 handle 时是否调用 create()（只有 acquire 路径为 true）
function Slot:_sync(allow_create)
  local top = self._tokens[#self._tokens]
  if not top then
    if self._handle then self._handle:stop() end
    self._handle = nil
    return
  end
  if not self._handle or not self._handle:is_active() then
    if not allow_create then return end
    self._handle = self._create()
  end
  self._handle:set_label(top.label)
end

--- 登记一个在途请求，返回幂等且不抛错的 release（只递减计数、同步文案，不重建已失效的 handle）
--- create() 抛错时回滚本次登记（不留下永远释放不掉的计数）并把错误原样抛给调用方
---@param label? string
---@return fun() release
function Slot:acquire(label)
  local token = { label = label }
  self._tokens[#self._tokens + 1] = token
  local ok, err = pcall(self._sync, self, true)
  if not ok then
    for i, t in ipairs(self._tokens) do
      if t == token then
        table.remove(self._tokens, i)
        break
      end
    end
    error(err, 0)
  end

  return function()
    for i, t in ipairs(self._tokens) do
      if t == token then
        table.remove(self._tokens, i)
        self:_sync(false)
        return
      end
    end
  end
end

---@return boolean
function Slot:is_busy()
  return #self._tokens > 0
end

--- 释放所有在途登记并停止显示（owner 关闭时调用），幂等
function Slot:dispose()
  self._tokens = {}
  self:_sync(false)
end

return M

---@class vv-utils.loading.Slot
---@field private _create fun(): vv-utils.loading.Handle
---@field private _handle vv-utils.loading.Handle?
---@field private _tokens { label: string? }[]
