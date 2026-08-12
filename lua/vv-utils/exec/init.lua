-- vv-utils.exec 公共入口：按固定优先级编排 shebang、项目入口与扩展名 runner

local Common = require('vv-utils.exec.common')
local Confirm = require('vv-utils.exec.confirm')
local ProjectRunners = require('vv-utils.exec.parsers')
local Shebang = require('vv-utils.exec.parsers.shebang')
local Runners = require('vv-utils.exec.runners')
local Source = require('vv-utils.exec.source')

local M = {}
M.common = Common
M.confirm = Confirm
M.parsers = ProjectRunners
M.runners = Runners
M.source = Source

---@alias VVExecRunnerPrefix string[]
---@alias VVExecRunnerList VVExecRunnerPrefix[]

---@class VVExecPlan
---@field cmd string[] 完整 argv；不经过 shell 拼接
---@field runner string 实际使用的 runner 名称
---@field cwd? string 执行目录；由项目解析器或自定义计划显式提供
---@field target? 'file'|'project' UI 提示目标类型；内置项目解析器返回 'project'

---@alias VVExecProjectRunner fun(path: string): VVExecPlan?

---@class VVExecConfig
---@field shebang? boolean 优先读 shebang 决定解释器 @default true
---@field project_runners? table<string, false|VVExecProjectRunner> 项目型语言解析器；键为小写扩展名，false 禁用内置解析器，返回 nil 时继续普通扩展名 runner @default Rust/Go
---@field runners? table<string, VVExecRunnerList> 扩展名(小写) → 运行器优先级；每项是 argv 前缀，命中后追加文件绝对路径，取首个可执行者 @default 见下
local defaults = {
  shebang = true,
  project_runners = ProjectRunners,
  runners = Runners,
}

---@param path string
---@param opts? VVExecConfig 深合并进默认（project_runners / runners 可增减、改优先级）
---@return VVExecPlan? plan, string? err
function M.resolve(path, opts)
  if not path or path == '' then return nil, 'empty path' end

  local config = opts and vim.tbl_deep_extend('force', {}, defaults, opts) or defaults
  local absolute_path = vim.fn.fnamemodify(path, ':p')

  if config.shebang ~= false then
    local prefix = Shebang.parse(absolute_path)
    local source_dir = vim.fs.dirname(absolute_path)

    if prefix and Common.executable(prefix, source_dir) then
      local executable_prefix = Common.normalize_prefix(prefix, source_dir)
      return {
        cmd = Common.append_path(executable_prefix, absolute_path),
        runner = prefix[1],
        target = 'file',
      }
    end
  end

  local extension = absolute_path:match('%.([%w_]+)$')
  if not extension then
    return nil, 'Unknown file type: ' .. vim.fs.basename(absolute_path) .. ' (no shebang and no matching extension)'
  end
  extension = extension:lower()

  local project_runner = config.project_runners[extension]
  if type(project_runner) == 'function' then
    local plan = project_runner(absolute_path)
    if plan then return plan end
  end

  local candidates = config.runners[extension]
  if not candidates then
    return nil, 'Unknown file type: .' .. extension .. ' (no shebang and no matching extension)'
  end

  for _, prefix in ipairs(candidates) do
    local source_dir = vim.fs.dirname(absolute_path)
    if Common.executable(prefix, source_dir) then
      local executable_prefix = Common.normalize_prefix(prefix, source_dir)
      return {
        cmd = Common.append_path(executable_prefix, absolute_path),
        runner = prefix[1],
        target = 'file',
      }
    end
  end

  local names = {}
  for _, prefix in ipairs(candidates) do names[#names + 1] = prefix[1] end
  return nil, ('.%s: no available runner (requires one of: %s)'):format(extension, table.concat(names, ', '))
end

return M
