-- 系统集成工具：跨平台分派外部程序

local M = {}
local focus_scope = require('vv-utils.async').scope({ cancel_previous = true })

-- 是否在 niri 会话中（用其 IPC socket 探测）
local function on_niri()
  return (vim.env.NIRI_SOCKET or '') ~= ''
end

-- app_id 与 desktop 词干宽松匹配（大小写无关、互为子串），兼容 firefox / org.gnome.eog 等形态
---@param app_id string?
---@param stem string
---@return boolean
local function app_matches(app_id, stem)
  if not app_id then return false end
  local a, s = app_id:lower(), stem:lower()
  return a == s or a:find(s, 1, true) ~= nil or s:find(a, 1, true) ~= nil
end

-- 轮询 niri 窗口列表，找到处理该文件的窗口并聚焦
-- 命中优先级：app_id 命中且标题含文件名 > app_id 命中 > 标题含文件名
-- 热启动（应用已在）立即命中；冷启动等窗口出现，最多约 2.5s
---@param request vv-utils.async.Request
---@param resources { add_process: fun(self, process: table), add_timer: fun(self, timer: table) }
---@param stem string 默认处理程序的 desktop 词干（如 'firefox'）
---@param base string 文件名（用于标题匹配，可为空串）
local function poll_focus(request, resources, stem, base)
  local tries = 0

  local function attempt()
    if not request:is_current() then return end
    tries = tries + 1
    local process = vim.system({ 'niri', 'msg', '--json', 'windows' }, { text = true }, function(out)
      if not request:is_current() then return end
      local ok, wins = pcall(vim.json.decode, out.stdout or '')
      local best, by_app, by_title

      if ok and type(wins) == 'table' then
        for _, w in ipairs(wins) do
          if not w.is_focused then -- 跳过发起打开的当前窗口（终端）
            local title_hit = base ~= '' and w.title and w.title:find(base, 1, true) ~= nil
            local app_hit = app_matches(w.app_id, stem)
            if app_hit and title_hit then
              best = w.id
              break
            end
            if app_hit then by_app = by_app or w.id end
            if title_hit then by_title = by_title or w.id end
          end
        end
      end

      local target = best or by_app or by_title
      if target then
        vim.system({ 'niri', 'msg', 'action', 'focus-window', '--id', tostring(target) })
        request:finish()
      elseif tries < 12 then
        resources:add_timer(vim.defer_fn(attempt, 200))
      else
        request:finish()
      end
    end)
    resources:add_process(process)
  end

  resources:add_timer(vim.defer_fn(attempt, 80))
end

-- niri 会丢弃应用的 xdg-activation 聚焦请求（焦点防抢），打开后主动把目标窗口聚焦回来
---@param request vv-utils.async.Request
---@param resources { add_process: fun(self, process: table), add_timer: fun(self, timer: table) }
---@param path string
local function niri_focus_handler(request, resources, path)
  local base = vim.fs.basename(path)

  -- 异步解析该文件默认处理程序的 desktop 词干（不阻塞打开按键）
  local filetype_process = vim.system({ 'xdg-mime', 'query', 'filetype', path }, { text = true }, function(o1)
    if not request:is_current() then return end
    if o1.code ~= 0 then request:finish() return end
    local mime = vim.trim(o1.stdout or '')
    if mime == '' then request:finish() return end

    local default_process = vim.system({ 'xdg-mime', 'query', 'default', mime }, { text = true }, function(o2)
      if not request:is_current() then return end
      if o2.code ~= 0 then request:finish() return end
      local desktop = vim.trim(o2.stdout or '')
      if desktop == '' then request:finish() return end

      poll_focus(request, resources, (desktop:gsub('%.desktop$', '')), base)
    end)
    resources:add_process(default_process)
  end)
  resources:add_process(filetype_process)
end

-- 用系统默认程序打开路径（跨平台，封装 vim.ui.open，Neovim 0.10+ 内置）：
--   * 目录 → 系统文件管理器（macOS Finder / Linux 文件管理器 / Windows 资源管理器）
--   * 文件 → 按文件关联的默认程序
-- 无可用 opener（如纯 headless / SSH 无 GUI）时通知并返回 false，不再静默吞错
-- niri 下额外把被打开的应用窗口主动聚焦回来（niri 默认丢弃应用的聚焦请求）
---@param path string
---@return boolean ok  唤起外部程序成功为 true；路径为空或无 opener 为 false
function M.open_default(path)
  if not path or path == '' then return false end

  local request = focus_scope:begin()

  local handle, err = vim.ui.open(path)
  if not handle then
    request:dispose()
    vim.notify('vv-utils.sys: ' .. (err or ('failed to open ' .. path)), vim.log.levels.ERROR)
    return false
  end

  if on_niri() then
    local resources = { processes = {}, timers = {}, state = 'active' }
    function resources:add_process(process)
      if self.state == 'cancelled' then
        pcall(function() process:kill('sigterm') end)
      elseif self.state == 'active' then
        self.processes[#self.processes + 1] = process
      end
    end
    function resources:add_timer(timer)
      if self.state ~= 'active' then
        if not timer:is_closing() then
          timer:stop()
          timer:close()
        end
      else
        self.timers[#self.timers + 1] = timer
      end
    end
    local function close_timers()
      for _, timer in ipairs(resources.timers) do
        if not timer:is_closing() then
          timer:stop()
          timer:close()
        end
      end
      resources.timers = {}
    end
    local function cancel_resources()
      if resources.state ~= 'active' then return end
      resources.state = 'cancelled'
      close_timers()
      for _, process in ipairs(resources.processes) do
        pcall(function() process:kill('sigterm') end)
      end
      resources.processes = {}
    end
    local function dispose_resources()
      if resources.state == 'active' then resources.state = 'finished' end
      close_timers()
      if resources.state == 'finished' then resources.processes = {} end
    end
    request:set_cancel(cancel_resources)
    request:set_disposer(dispose_resources)
    niri_focus_handler(request, resources, path)
  else
    request:finish()
  end

  return true
end

return M
