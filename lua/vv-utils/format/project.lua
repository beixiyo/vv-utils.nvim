-- 项目级文本清理
--
-- 负责 Git 文件枚举、二进制过滤、文件读写和汇总通知

local Fs = require('vv-utils.fs')
local Git = require('vv-utils.git')
local Text = require('vv-utils.format.text')

local M = {}

---@param path string
---@return boolean
local function is_binary(path)
  local file = io.open(path, 'rb')
  if not file then return true end
  local chunk = file:read(8192) or ''
  file:close()
  return chunk:find('\0', 1, true) ~= nil
end

---@param opts vv-utils.format.ProjectOpts
---@param config { prose_filetypes: table<string, boolean>, punct: string[] }
---@return { scanned: integer, changed: integer, skipped_binary: integer, files: string[] }
function M.clean(opts, config)
  local root = opts.cwd or Git.root() or vim.uv.cwd()

  local args = { 'git', '-c', 'core.quotePath=false', '-C', root, 'ls-files' }
  if opts.include_untracked then
    args[#args + 1] = '--others'
    args[#args + 1] = '--exclude-standard'
  end
  local relative_paths = vim.fn.systemlist(args)
  local stat = { scanned = 0, changed = 0, skipped_binary = 0, files = {} }
  if vim.v.shell_error ~= 0 then
    vim.notify('git ls-files 失败（不是 git 仓库？）: ' .. root, vim.log.levels.ERROR, { title = 'vv-utils.format' })
    return stat
  end

  for _, relative_path in ipairs(relative_paths) do
    if relative_path ~= '' then
      local path = root .. '/' .. relative_path
      if vim.uv.fs_stat(path) then
        if is_binary(path) then
          stat.skipped_binary = stat.skipped_binary + 1
        else
          local ok, content = pcall(Fs.read_all, path)
          if ok and content then
            stat.scanned = stat.scanned + 1
            local filetype = vim.filetype.match({ filename = path }) or ''
            local processed = config.prose_filetypes[filetype]
              and Text.clean_prose(content, config.punct)
              or Text.clean_code(content, config.punct)
            if processed ~= content then
              stat.changed = stat.changed + 1
              stat.files[#stat.files + 1] = relative_path
              if not opts.dry_run then pcall(Fs.write_all, path, processed) end
            end
          end
        end
      end
    end
  end

  if not opts.silent then
    local verb = opts.dry_run and '将清理' or '已清理'
    vim.notify(('%s %d / %d 文件（跳过二进制 %d）'):format(
      verb,
      stat.changed,
      stat.scanned,
      stat.skipped_binary
    ), vim.log.levels.INFO, { title = 'vv-utils.format' })
  end
  return stat
end

return M
