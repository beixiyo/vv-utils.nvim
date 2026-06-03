-- 按文件类型决定「该用什么命令执行」：shebang > 扩展名优先级 > （无则报错）
-- 纯函数、无副作用：只解析出要运行的 argv，怎么跑（终端/后台）交给调用方

local M = {}

-- 读首行 shebang，解析出解释器 argv 前缀（如 {'bash'} / {'python3'}）；无则 nil
-- `/usr/bin/env foo` 形态丢掉 env 这层，取真正解释器
---@param path string
---@return string[]?
local function parse_shebang(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local chunk = f:read(512) or '' -- 只读头部，避免对无换行大文件全量扫描
  f:close()

  local line = chunk:match('^#!([^\n]*)')
  if not line then return nil end

  local parts = {}
  for tok in line:gmatch('%S+') do parts[#parts + 1] = tok end

  local first = parts[1]
  if first and (first == 'env' or first:match('/env$')) then
    table.remove(parts, 1)
    -- 现代 `env -S foo bar` 多参 shebang：再剥掉 -S / --split-string
    if parts[1] == '-S' or parts[1] == '--split-string' then
      table.remove(parts, 1)
    end
  end
  return parts[1] and parts or nil
end

-- argv 前缀的第一个元素是否可执行
---@param prefix string[]
---@return boolean
local function usable(prefix)
  return prefix[1] ~= nil and vim.fn.executable(prefix[1]) == 1
end

-- 把 argv 前缀 + 文件绝对路径拼成完整命令（不改动 defaults 里的前缀）
---@param prefix string[]
---@param abspath string
---@return string[]
local function build_cmd(prefix, abspath)
  local cmd = vim.deepcopy(prefix)
  cmd[#cmd + 1] = abspath
  return cmd
end

---@class VVExecConfig
---@field shebang boolean  优先读 shebang 决定解释器 @default true
---@field runners table<string, string[][]>  扩展名(小写) → 运行器优先级；每项是 argv 前缀，命中后追加文件绝对路径，取首个可执行者 @default 见下
local defaults = {
  shebang = true,
  runners = {
    sh   = { { 'bash' }, { 'sh' } },
    bash = { { 'bash' } },
    zsh  = { { 'zsh' } },
    fish = { { 'fish' } },
    ts   = { { 'bun', 'run' }, { 'tsx' }, { 'deno', 'run' }, { 'ts-node' } },
    tsx  = { { 'bun', 'run' }, { 'tsx' }, { 'deno', 'run' } },
    mts  = { { 'bun', 'run' }, { 'tsx' }, { 'deno', 'run' } },
    cts  = { { 'bun', 'run' }, { 'tsx' }, { 'deno', 'run' } },
    js   = { { 'bun' }, { 'node' }, { 'deno', 'run' } },
    mjs  = { { 'bun' }, { 'node' }, { 'deno', 'run' } },
    cjs  = { { 'bun' }, { 'node' }, { 'deno', 'run' } },
    py   = { { 'python3' }, { 'python' } },
    lua  = { { 'lua' }, { 'luajit' } },
    rb   = { { 'ruby' } },
    pl   = { { 'perl' } },
    php  = { { 'php' } },
  },
}

-- 解析某文件的执行命令
---@param path string
---@param opts? VVExecConfig  深合并进默认（runners 可增减、改优先级）
---@return { cmd: string[], runner: string }? plan, string? err
function M.resolve(path, opts)
  if not path or path == '' then return nil, 'empty path' end

  local cfg = opts and vim.tbl_deep_extend('force', defaults, opts) or defaults
  local abspath = vim.fn.fnamemodify(path, ':p')

  -- 1) shebang —— 显式作者意图优先（覆盖扩展名）
  if cfg.shebang ~= false then
    local sb = parse_shebang(abspath)
    if sb and usable(sb) then
      return { cmd = build_cmd(sb, abspath), runner = sb[1] }
    end
  end

  -- 2) 扩展名优先级 —— 取首个可执行的运行器
  local ext = abspath:match('%.([%w_]+)$')
  if ext then
    local list = cfg.runners[ext:lower()]
    if list then
      for _, prefix in ipairs(list) do
        if usable(prefix) then
          return { cmd = build_cmd(prefix, abspath), runner = prefix[1] }
        end
      end

      local names = {}
      for _, p in ipairs(list) do names[#names + 1] = p[1] end
      return nil, ('.' .. ext .. ': 无可用运行器（需其一：' .. table.concat(names, ', ') .. '）')
    end
  end

  return nil, ('未知文件类型：' .. (ext and ('.' .. ext) or vim.fs.basename(abspath)) .. '（无 shebang、无匹配扩展名）')
end

return M
