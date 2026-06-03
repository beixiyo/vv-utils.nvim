-- 系统集成工具：跨平台分派外部程序

local M = {}

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
---@param stem string  默认处理程序的 desktop 词干（如 'firefox'）
---@param base string  文件名（用于标题匹配，可为空串）
local function poll_focus(stem, base)
  local tries = 0

  local function attempt()
    tries = tries + 1
    vim.system({ 'niri', 'msg', '--json', 'windows' }, { text = true }, function(out)
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
      elseif tries < 12 then
        vim.defer_fn(attempt, 200)
      end
    end)
  end

  vim.defer_fn(attempt, 80)
end

-- niri 会丢弃应用的 xdg-activation 聚焦请求（焦点防抢），打开后主动把目标窗口聚焦回来
---@param path string
local function niri_focus_handler(path)
  local base = vim.fs.basename(path)

  -- 异步解析该文件默认处理程序的 desktop 词干（不阻塞打开按键）
  vim.system({ 'xdg-mime', 'query', 'filetype', path }, { text = true }, function(o1)
    if o1.code ~= 0 then return end
    local mime = vim.trim(o1.stdout or '')
    if mime == '' then return end

    vim.system({ 'xdg-mime', 'query', 'default', mime }, { text = true }, function(o2)
      if o2.code ~= 0 then return end
      local desktop = vim.trim(o2.stdout or '')
      if desktop == '' then return end

      poll_focus((desktop:gsub('%.desktop$', '')), base)
    end)
  end)
end

-- 用系统默认程序打开路径（跨平台，封装 vim.ui.open，Neovim 0.10+ 内置）：
--   * 目录 → 系统文件管理器（macOS Finder / Linux 文件管理器 / Windows 资源管理器）
--   * 文件 → 按文件关联的默认程序
-- 无可用 opener（如纯 headless / SSH 无 GUI）时通知并返回 false，不再静默吞错。
-- niri 下额外把被打开的应用窗口主动聚焦回来（niri 默认丢弃应用的聚焦请求）。
---@param path string
---@return boolean ok  唤起外部程序成功为 true；路径为空或无 opener 为 false
function M.open_default(path)
  if not path or path == '' then return false end

  local handle, err = vim.ui.open(path)
  if not handle then
    vim.notify('vv-utils.sys: ' .. (err or ('failed to open ' .. path)), vim.log.levels.ERROR)
    return false
  end

  if on_niri() then niri_focus_handler(path) end

  return true
end

return M
