-- vv-utils.format — 中英文排版与行尾清理
--
-- 算法对齐 https://github.com/beixiyo/vsc-word-space
--
-- 纯函数：
--   add_spaces_around_english(text)  中英文之间智能加空格
--   clean_prose(text)                散文：删行尾句号 + 闭合符遮挡的句号 + 行尾空白（跳代码围栏、不删 ？！）
--   clean_code(text)                 代码：删行尾句号 + 行尾空白（字符串/缩进天然安全）
--
-- Buffer 副作用（Visual 有选区时只处理选区，否则处理全文）：
--   add_spaces()       对当前 buffer 应用加空格
--   clean_trailing()   对当前 buffer 应用行尾清理

local M = {}

-- 中文范围：CJK Unified Ideographs 主区段（U+4E00-U+9FA5）
-- 与 vsc-word-space 原版 U+4E00-U+9FFF 略小，但 U+9FA6+ 在中文排版中几乎不出现，无实际影响
--
-- 左侧：中文；右侧：(允许的前缀符号*)英数。前缀符号：@#$¥€£+_-*~`[
local LEFT_PATTERN  = [=[\([一-龥]\)\([@#$¥€£+_\-*~`[]*[A-Za-z0-9]\)]=]
-- 左侧：英数(允许的后缀符号*)；右侧：中文。后缀符号：+-%‰°_*~`)]
local RIGHT_PATTERN = [=[\([A-Za-z0-9][+\-%‰°_*~`)\]]*\)\([一-龥]\)]=]

-- 行尾「闭合符」：markdown 强调 / 行内代码 / 删除线 + 各类闭合括号 / 引号
-- 句号被这些闭合符挡在行尾时（如 `重点。**`、`（说明。）`），句号仍应删除、闭合符保留
local TRAILING_CLOSERS = {
  '*', '_', '`', '~',
  ')', ']', '}', '）', '】', '》', '」', '』', '〉', '〕', '］', '｝',
  '”', '“', '’', '‘', '"', "'",
}
-- 模块配置（M.setup 可覆盖 / 合并）。提前声明，供下方纯函数读取
local config = {
  -- 这些 filetype 视为「散文」：删句号 + 闭合符遮挡的句号 + 空白；其余文件只删行尾句号 + 空白。
  -- buffer 按 vim.bo.filetype 判定，clean_project 按 vim.filetype.match(文件名) 判定 —— 同一份 prose_filetypes
  prose_filetypes = {
    markdown = true, markdown_inline = true, pandoc = true, rmd = true,
    text = true, txt = true, asciidoc = true, rst = true, org = true, vimwiki = true,
  },

  -- 行尾要删除的标点集（可配置）。默认仅句号，避免误删问句 / 感叹句；要连 ！？ 在此加
  punct = { '。' },
}

-- 清理单行行尾：只删「真正的行尾空白 + 行尾标点」；peel_closers 为真时还删「被行尾闭合符直接遮挡的标点」。
-- 绝不动「内部空白」（代码缩进 / 字符串内空格）。例：'  }' 保持 '  }'，"'✓ '" 保持 "'✓ '"
---@param line string
---@param puncts string[]
---@param peel_closers boolean  true=散文（连闭合符遮挡的句号一起删）；false=代码（仅行尾句号）
---@return string
local function clean_one_line(line, puncts, peel_closers)
  -- 1) 去真正的行尾空白 + 行尾标点（标点删后又露出的空白也一并去）
  while true do
    local before = line
    line = line:gsub('[ \t]+$', '')
    for _, p in ipairs(puncts) do
      if vim.endswith(line, p) then line = line:sub(1, #line - #p); break end
    end
    if line == before then break end
  end
  if not peel_closers then return line end
  -- 2) 把行尾闭合符剥到栈里（不动任何空白，保留缩进 / 串内空格）
  local closers = {}
  while true do
    local matched = false
    for _, c in ipairs(TRAILING_CLOSERS) do
      if vim.endswith(line, c) then
        closers[#closers + 1] = c
        line = line:sub(1, #line - #c)
        matched = true
        break
      end
    end
    if not matched then break end
  end
  -- 3) 闭合符背后若「直接」是标点则删（仍不动空白：串内 '✓ ' 的空格不会被吃）
  while true do
    local matched = false
    for _, p in ipairs(puncts) do
      if vim.endswith(line, p) then
        line = line:sub(1, #line - #p)
        matched = true
        break
      end
    end
    if not matched then break end
  end
  -- 4) 复原闭合符
  for j = #closers, 1, -1 do line = line .. closers[j] end
  return line
end

--- 中英文之间智能加空格（前缀 / 后缀符号会被推到外侧，保留 markdown 格式如 **bold**）
---@param text string
---@return string
function M.add_spaces_around_english(text)
  text = vim.fn.substitute(text, LEFT_PATTERN, [[\1 \2]], 'g')
  text = vim.fn.substitute(text, RIGHT_PATTERN, [[\1 \2]], 'g')
  return text
end

-- 取当前 visual 选区的行号范围 [s_row, e_row]（1-based, inclusive）
-- 返回 nil 表示当前不在 visual 模式
---@return integer?, integer?
local function visual_line_range()
  local mode = vim.fn.mode()
  if not (mode == 'v' or mode == 'V' or mode == '\22') then return nil end
  -- 退出可视模式以更新 '< '> 标记
  vim.cmd([[execute "normal! \<Esc>"]])
  local s = vim.api.nvim_buf_get_mark(0, '<')[1]
  local e = vim.api.nvim_buf_get_mark(0, '>')[1]
  if s > e then s, e = e, s end
  return s, e
end

--- 把 transform 应用到当前 buffer
--- 优先级：显式 opts.range > visual 选区嗅探 > 全文
---@param transform fun(text: string): string
---@param opts? { range?: integer[], msg_changed?: string, msg_unchanged?: string, silent?: boolean}
function M.apply_to_buffer(transform, opts)
  opts = opts or {}

  local from_row, to_row
  if opts.range then
    from_row, to_row = opts.range[1] - 1, opts.range[2]
  else
    local s_row, e_row = visual_line_range()
    if s_row then
      from_row, to_row = s_row - 1, e_row
    else
      from_row, to_row = 0, -1
    end
  end

  local lines = vim.api.nvim_buf_get_lines(0, from_row, to_row, false)
  -- vim.fn.substitute() treats Lua strings with NUL bytes as VimL Blobs (E976); strip them
  for i, line in ipairs(lines) do
    lines[i] = line:gsub('%z','')
  end
  local original = table.concat(lines, '\n')
  local processed = transform(original)

  if processed == original then
    if not opts.silent then
      vim.notify(opts.msg_unchanged or 'Nothing to process', vim.log.levels.INFO, { title = 'vv-utils.format'})
    end
    return false
  end

  -- set_lines 作用于当前 buffer（0），故 vim.bo.modifiable 判的就是它
  -- help/quickfix/只读 buffer 上若直接写入会抛 E21，这里友好返回
  if not vim.bo.modifiable then
    if not opts.silent then
      vim.notify('buffer 不可修改', vim.log.levels.WARN, { title = 'vv-utils.format'})
    end
    return false
  end

  local new_lines = vim.split(processed, '\n', { plain = true})
  vim.api.nvim_buf_set_lines(0, from_row, to_row, false, new_lines)

  if not opts.silent and opts.msg_changed then
    vim.notify(opts.msg_changed, vim.log.levels.INFO, { title = 'vv-utils.format'})
  end
  return true
end

--- 当前 buffer：中英文之间加空格
---@param opts? { range?: integer[], silent?: boolean}
function M.add_spaces(opts)
  return M.apply_to_buffer(M.add_spaces_around_english, vim.tbl_extend('keep', opts or {}, {
    msg_changed = '已为中英文之间添加空格',
    msg_unchanged = '没有找到需要处理的文本',
}))
end

--- 当前 buffer：清理行尾。按 filetype 分派：散文 → clean_prose；其余 → clean_code。
--- opts.force_full 强制按散文处理（:VVCleanTrailing! 用）
---@param opts? { range?: integer[], silent?: boolean, force_full?: boolean}
function M.clean_trailing(opts)
  opts = opts or {}
  local is_prose = opts.force_full or config.prose_filetypes[vim.bo.filetype] or false
  local transform = is_prose and M.clean_prose or M.clean_code
  return M.apply_to_buffer(transform, vim.tbl_extend('keep', opts, {
    msg_changed = is_prose and '已删除行尾句号 / 闭合符 / 空白' or '已删除行尾句号与空白',
    msg_unchanged = '没有找到需要处理的内容',
}))
end

--- 散文清理：跳过 ``` / ~~~ 代码围栏，对其余行做「仅句号 + 闭合符 + 行尾空白」清理
--- （批量安全：不删 ？！，避免误删问句 / 感叹句标题）
---@param text string
---@return string
function M.clean_prose(text)
  local lines = vim.split(text, '\n', { plain = true})
  local in_code = false
  for i, line in ipairs(lines) do
    if line:match('^%s*```') or line:match('^%s*~~~') then
      in_code = not in_code
    elseif not in_code then
      lines[i] = clean_one_line(line, config.punct, true)
    end
  end
  return table.concat(lines, '\n')
end

--- 代码 / 配置文件清理：每行删「行尾空白 + 行尾句号」。
--- 不必检测注释 / 字符串：任何语言合法语法都不会以句号或空格收尾，故行尾句号必是「注释里的或多余的」——直接删；
--- 字符串内的句号（如 `'完成。'`）后面跟着引号，不在行尾，天然不受影响。
---@param text string
---@return string
function M.clean_code(text)
  local lines = vim.split(text, '\n', { plain = true })
  for i, line in ipairs(lines) do
    lines[i] = clean_one_line(line, config.punct, false)
  end
  return table.concat(lines, '\n')
end

-- 二进制嗅探：前 8KB 含 NUL 字节即判为二进制
---@param path string
---@return boolean
local function is_binary(path)
  local fh = io.open(path, 'rb')
  if not fh then return true end
  local chunk = fh:read(8192) or''
  fh:close()
  return chunk:find('\0', 1, true) ~= nil
end

---@class vv-utils.format.ProjectOpts
---@field cwd? string                项目根；默认 git toplevel，退回 cwd
---@field dry_run? boolean           只统计不写入 @default false
---@field include_untracked? boolean 含未跟踪（非 gitignore）文件 @default false

--- 项目级清理：遍历 git 跟踪的非二进制文本文件。
--- 散文（vim.filetype.match 命中 prose_filetypes）→ clean_prose；其余 → clean_code。
---@param opts? vv-utils.format.ProjectOpts
---@return { scanned: integer, changed: integer, skipped_binary: integer, files: string[]}
function M.clean_project(opts)
  opts = opts or {}
  local root = opts.cwd or require('vv-utils.git').root() or vim.uv.cwd()
  local fs = require('vv-utils.fs')

  -- core.quotePath=false 让中文 / 非 ASCII 路径原样输出（否则 git 会转义成八进制）
  local args = { 'git', '-c', 'core.quotePath=false', '-C', root, 'ls-files' }
  if opts.include_untracked then
    args[#args + 1] = '--others'
    args[#args + 1] = '--exclude-standard'
  end
  local rels = vim.fn.systemlist(args)   -- 按行分割，回避 -z 的 NUL 被转成 \x01 的坑
  local stat = { scanned = 0, changed = 0, skipped_binary = 0, files = {} }
  if vim.v.shell_error ~= 0 then
    vim.notify('git ls-files 失败（不是 git 仓库？）: ' .. root, vim.log.levels.ERROR, { title = 'vv-utils.format' })
    return stat
  end

  for _, rel in ipairs(rels) do
    if rel ~= '' then
      local path = root .. '/' .. rel
      if vim.uv.fs_stat(path) then
        if is_binary(path) then
          stat.skipped_binary = stat.skipped_binary + 1
        else
          local ok, content = pcall(fs.read_all, path)
          if ok and content then
            stat.scanned = stat.scanned + 1
            -- 散文判定与 buffer 同源：vim.filetype.match(文件名) 命中 prose_filetypes 即按散文清理
            local ft = vim.filetype.match({ filename = path }) or ''
            local processed = config.prose_filetypes[ft] and M.clean_prose(content) or M.clean_code(content)
            if processed ~= content then
              stat.changed = stat.changed + 1
              stat.files[#stat.files + 1] = rel
              if not opts.dry_run then pcall(fs.write_all, path, processed) end
            end
          end
        end
      end
    end
  end

  if not opts.silent then
    local verb = opts.dry_run and '将清理' or '已清理'
    vim.notify(('%s %d / %d 文件（跳过二进制 %d）'):format(verb, stat.changed, stat.scanned, stat.skipped_binary),
      vim.log.levels.INFO, { title = 'vv-utils.format' })
  end
  return stat
end

---@class vv-utils.format.Opts
---@field commands? boolean  是否注册 :VVAddSpaces / :VVCleanTrailing / :VVCleanTrailingProject user command（默认 true）
---@field prose_filetypes? table<string,boolean>  视为散文（删句号）的 filetype 集；其余仅删空白。与默认合并
---@field punct? string[]  批量 / 散文文件 / 代码注释 行尾删除的标点集（默认仅句号）

--- 启用 format 模块的副作用：注册 user command（keymap 由用户自行在配置层绑定）
---@param opts? vv-utils.format.Opts
function M.setup(opts)
  opts = opts or {}
  if type(opts.prose_filetypes) == 'table' then
    -- 与默认合并：设 true 加入散文集、设 false 移除（如 { yaml = true } 或 { markdown = false}）
    config.prose_filetypes = vim.tbl_extend('force', config.prose_filetypes, opts.prose_filetypes)
  end
  if type(opts.punct) == 'table' then config.punct = opts.punct end
  if opts.commands == false then return end

  -- ctx.range > 0 → 显式带 range（如 :5,10VVAddSpaces 或 visual `:` 自动 prepend '<,'>）
  -- ctx.range == 0 → 让 add_spaces() 自己嗅探 visual 选区或退回全文
  vim.api.nvim_create_user_command('VVAddSpaces', function(ctx)
    M.add_spaces(ctx.range > 0 and { range = { ctx.line1, ctx.line2 } } or nil)
  end, { range = true, desc = 'vv-utils.format: 中英文之间智能加空格'})

  vim.api.nvim_create_user_command('VVCleanTrailing', function(ctx)
    M.clean_trailing(vim.tbl_extend('force',
      ctx.range > 0 and { range = { ctx.line1, ctx.line2 } } or {},
      { force_full = ctx.bang}))
  end, { range = true, bang = true, desc = 'vv-utils.format: 清理行尾（代码仅空白；! 连句号一起删）'})

  -- 项目级：散文删句号+闭合符+空白，其它文本仅删空白；`!` 为 dry-run 预览
  vim.api.nvim_create_user_command('VVCleanTrailingProject', function(ctx)
    local r = M.clean_project({ dry_run = ctx.bang})
    if ctx.bang and #r.files > 0 then
      vim.notify('将清理：\n  ' .. table.concat(r.files, '\n  '), vim.log.levels.INFO, { title = 'vv-utils.format'})
    end
  end, { bang = true, desc = 'vv-utils.format: 项目级清理行尾（! 预览不写入）'})
end

return M
