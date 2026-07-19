-- vv-utils.format — 中英文排版与行尾清理
--
-- 正式领域 facade：持有配置，暴露文本、buffer、项目 API，并按需注册 user command

local Buffer = require('vv-utils.format.buffer')
local Text = require('vv-utils.format.text')

local M = {}

local config = {
  prose_filetypes = {
    markdown = true, markdown_inline = true, pandoc = true, rmd = true,
    text = true, txt = true, asciidoc = true, rst = true, org = true, vimwiki = true,
  },
  punct = { '。' },
}

---中英文之间智能加空格
---@param text string
---@return string
function M.add_spaces_around_english(text)
  return Text.add_spaces_around_english(text)
end

---散文清理：代码围栏内只清注释行句号，其余行清理标点、闭合符和行尾空白
---@param text string
---@return string
function M.clean_prose(text)
  return Text.clean_prose(text, config.punct)
end

---代码或配置文件清理：删除行尾标点和空白
---@param text string
---@return string
function M.clean_code(text)
  return Text.clean_code(text, config.punct)
end

---把文本变换应用到当前 buffer
---@param transform fun(text: string): string
---@param opts? { range?: integer[], msg_changed?: string, msg_unchanged?: string, silent?: boolean }
---@return boolean changed
function M.apply_to_buffer(transform, opts)
  return Buffer.apply(transform, opts)
end

---当前 buffer：中英文之间加空格
---@param opts? { range?: integer[], silent?: boolean }
---@return boolean changed
function M.add_spaces(opts)
  return Buffer.apply(M.add_spaces_around_english, vim.tbl_extend('keep', opts or {}, {
    msg_changed = '已为中英文之间添加空格',
    msg_unchanged = '没有找到需要处理的文本',
  }))
end

---当前 buffer：按 filetype 清理行尾
---@param opts? { range?: integer[], silent?: boolean, force_full?: boolean }
---@return boolean changed
function M.clean_trailing(opts)
  opts = opts or {}
  local is_prose = opts.force_full or config.prose_filetypes[vim.bo.filetype] or false
  local transform = is_prose and M.clean_prose or M.clean_code
  return Buffer.apply(transform, vim.tbl_extend('keep', opts, {
    msg_changed = is_prose and '已删除行尾句号 / 闭合符 / 空白' or '已删除行尾句号与空白',
    msg_unchanged = '没有找到需要处理的内容',
  }))
end

---@class vv-utils.format.ProjectOpts
---@field cwd? string 项目根；默认 git toplevel，退回 cwd
---@field dry_run? boolean 只统计不写入 @default false
---@field include_untracked? boolean 含未跟踪（非 gitignore）文件 @default false
---@field silent? boolean 禁止汇总通知 @default false

---清理项目内 Git 跟踪的非二进制文本文件
---@param opts? vv-utils.format.ProjectOpts
---@return { scanned: integer, changed: integer, skipped_binary: integer, files: string[] }
function M.clean_project(opts)
  return require('vv-utils.format.project').clean(opts or {}, config)
end

---@class vv-utils.format.Opts
---@field commands? boolean 是否注册 format user commands @default true
---@field prose_filetypes? table<string, boolean> 视为散文的 filetype 集；与默认配置合并 @default nil
---@field punct? string[] 行尾删除的标点集 @default { '。' }

---启用 format 模块的副作用：注册 user command
---@param opts? vv-utils.format.Opts
function M.setup(opts)
  opts = opts or {}
  if type(opts.prose_filetypes) == 'table' then
    config.prose_filetypes = vim.tbl_extend('force', config.prose_filetypes, opts.prose_filetypes)
  end
  if type(opts.punct) == 'table' then config.punct = opts.punct end
  if opts.commands == false then return end

  vim.api.nvim_create_user_command('VVAddSpaces', function(ctx)
    M.add_spaces(ctx.range > 0 and { range = { ctx.line1, ctx.line2 } } or nil)
  end, { range = true, desc = 'vv-utils.format: 中英文之间智能加空格' })

  vim.api.nvim_create_user_command('VVCleanTrailing', function(ctx)
    M.clean_trailing(vim.tbl_extend('force',
      ctx.range > 0 and { range = { ctx.line1, ctx.line2 } } or {},
      { force_full = ctx.bang }))
  end, { range = true, bang = true, desc = 'vv-utils.format: 清理行尾（代码仅空白；! 连句号一起删）' })

  vim.api.nvim_create_user_command('VVCleanTrailingProject', function(ctx)
    local result = M.clean_project({ dry_run = ctx.bang })
    if ctx.bang and #result.files > 0 then
      vim.notify('将清理：\n  ' .. table.concat(result.files, '\n  '), vim.log.levels.INFO, {
        title = 'vv-utils.format',
      })
    end
  end, { bang = true, desc = 'vv-utils.format: 项目级清理行尾（! 预览不写入）' })
end

return M
