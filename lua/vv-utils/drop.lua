-- 终端拖拽路径检测 + handler 分发
--
-- 覆写 vim.paste，从 bracketed paste 中检测文件/目录路径，
-- 按注册顺序分发给 handler，首个返回 true 的 handler 消费事件。
-- 内置默认 handler：Normal 模式 + 普通 buffer 下自动 :edit 打开文件。
--
-- 各终端拖拽行为（对 TUI 应用如 Neovim）：
--   Kitty (Linux/macOS)     原始解码路径（无 shell 转义），换行分隔多文件，bracketed paste
--                           另有 OSC 72 新协议（0.47.0+），需 TUI 端 opt-in，Neovim 尚未支持
--   Ghostty (Linux/GTK4)    bracketed paste，shell-escaped 路径
--   Ghostty (macOS/AppKit)  insertText 击键输入，不走 bracketed paste —— 无法拦截
--                           无配置项可改变此行为（hardcoded，见 PR #4962 / Issue #4932）
--   WezTerm                 可配 quote_dropped_files: None | SpacesOnly | Posix | Windows
--   Alacritty / iTerm2      shell-escaped 路径，bracketed paste
--
-- 参考：
--   vim.paste API        :help vim.paste()  |  https://neovim.io/doc/user/lua.html#vim.paste()
--   bracketed paste      :help bracketed-paste  |  https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h3-Bracketed-Paste-Mode
--   Neovim Discussion    https://github.com/neovim/neovim/discussions/33567
--   Neovim Issue #24164  https://github.com/neovim/neovim/issues/24164
--   magenta.nvim         https://github.com/dlants/magenta.nvim/blob/main/lua/magenta/keymaps.lua
--   Kitty DnD 协议       https://sw.kovidgoyal.net/kitty/dnd-protocol/
--   Ghostty drag-drop    https://github.com/ghostty-org/ghostty/pull/4962

local M = {}

---@type (fun(paths: string[]): boolean?)[]
local handlers = {}
local original_paste

local function strip_quotes(s)
  if #s < 2 then return s end
  local f, l = s:sub(1, 1), s:sub(-1)
  if (f == '"' and l == '"') or (f == "'" and l == "'") then
    return s:sub(2, -2)
  end
  return s
end

local function shell_unescape(s)
  return (s:gsub('\\(.)', '%1'))
end

-- 把一个候选字符串规整成可 fs_stat 的绝对路径；非绝对路径返回 nil
---@param s string
---@return string?
local function normalize_candidate(s)
  if s:match('^file://') then
    s = vim.uri_to_fname(s)
  end
  if not s:match('^[/~]') then return nil end
  return (s:gsub('^~', vim.env.HOME or '~'))
end

---@param raw string
---@return string?
local function try_resolve_path(raw)
  raw = raw:gsub('^%s+', ''):gsub('%s+$', '')
  if raw == '' then return nil end

  -- 候选按优先级：
  --   1. 原始路径（Kitty 等原始解码终端，无 shell 转义，可含字面反斜杠）
  --   2. strip_quotes + shell_unescape 后备（Ghostty/Alacritty 等 shell-转义终端）
  -- 逐个 fs_stat，返回首个真实存在的，避免把合法的字面反斜杠误 strip 成错误路径
  local candidates = { raw }

  local unescaped = shell_unescape(strip_quotes(raw))
  if unescaped ~= raw then
    candidates[#candidates + 1] = unescaped
  end

  for _, cand in ipairs(candidates) do
    local expanded = normalize_candidate(cand)
    if expanded then
      local stat = vim.uv.fs_stat(expanded)
      if stat then return expanded end
    end
  end

  return nil
end

--- 检测粘贴内容中的文件/目录路径（绝对路径，/ 或 ~ 开头）
--- 所有行都必须是合法路径才返回，任一行不是则返回 nil
---@param lines string[]
---@return string[]?
function M.detect_paths(lines)
  local joined = table.concat(lines, '\n')
  joined = joined:gsub('^%s+', ''):gsub('%s+$', '')
  if joined == '' then return nil end

  local candidates = vim.split(joined, '\n', { trimempty = true })
  if #candidates == 0 then return nil end

  local paths = {}
  for _, raw in ipairs(candidates) do
    local p = try_resolve_path(raw)
    if not p then return nil end
    paths[#paths + 1] = p
  end

  return #paths > 0 and paths or nil
end

--- 注册拖拽处理器，返回 true 表示已消费，阻止后续 handler
---@param handler fun(paths: string[]): boolean?
function M.register(handler)
  handlers[#handlers + 1] = handler
end

--- 默认 handler：Normal 模式 + 普通 buffer 下打开文件
---@param paths string[]
---@return boolean
local function default_handler(paths)
  local mode = vim.fn.mode()
  if mode ~= 'n' and mode ~= 'nt' then return false end
  if vim.bo.buftype ~= '' then return false end

  for _, p in ipairs(paths) do
    local stat = vim.uv.fs_stat(p)
    if not stat or stat.type ~= 'file' then return false end
  end

  vim.schedule(function()
    for _, path in ipairs(paths) do
      vim.cmd('edit ' .. vim.fn.fnameescape(path))
    end
  end)
  return true
end

--- 安装 vim.paste 拦截 + 注册默认 handler
function M.setup()
  if original_paste then return end
  original_paste = vim.paste

  vim.paste = function(lines, phase)
    if phase ~= -1 then
      return original_paste(lines, phase)
    end

    local paths = M.detect_paths(lines)
    if not paths then
      return original_paste(lines, phase)
    end

    for _, handler in ipairs(handlers) do
      if handler(paths) then
        return false
      end
    end

    if default_handler(paths) then return false end
    return original_paste(lines, phase)
  end
end

return M
