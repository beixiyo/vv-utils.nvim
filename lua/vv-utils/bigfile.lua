-- 大文件保护
--
-- 机制：
--   ① 注册 `.*` 的 filetype 探测函数——命中"大小阈值"或"平均行长阈值"(识别 minified)
--      即返回 filetype = 'bigfile'
--   ② 监听 FileType=bigfile，禁用重开销特性（matchparen / folding / statuscolumn /
--      conceal / completion / mini.* 系列），再在下个 tick 用原 filetype 重挂 syntax
--
-- 用法：
--   require('vv-utils.bigfile').setup()
--   require('vv-utils.bigfile').setup({ size = 3 * 1024 * 1024, line_length = 500 })

local M = {}

---@class vv-utils.bigfile.Ctx
---@field buf integer
---@field ft  string

---@class vv-utils.bigfile.Opts
---@field notify? boolean                             触发时弹通知
---@field size? integer                               字节数硬阈值
---@field line_length? integer                        平均行长阈值（minified 识别）
---@field setup? fun(ctx: vv-utils.bigfile.Ctx): nil  自定义副作用（覆盖默认禁用项）
local defaults = {
  notify = true,
  size = 1.5 * 1024 * 1024,
  line_length = 1000,
  setup = function(ctx)
    if vim.fn.exists(':NoMatchParen') ~= 0 then
      vim.cmd('NoMatchParen')
    end
    for _, win in ipairs(vim.fn.win_findbuf(ctx.buf)) do
      vim.api.nvim_set_option_value('foldmethod', 'manual', { scope = 'local', win = win })
      vim.api.nvim_set_option_value('statuscolumn', '', { scope = 'local', win = win })
      vim.api.nvim_set_option_value('conceallevel', 0, { scope = 'local', win = win })
    end
    vim.b[ctx.buf].completion = false
    vim.b[ctx.buf].minianimate_disable = true
    vim.b[ctx.buf].minihipatterns_disable = true
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(ctx.buf) then
        vim.bo[ctx.buf].syntax = ctx.ft
      end
    end)
  end,
}

---@param user_opts? vv-utils.bigfile.Opts
function M.setup(user_opts)
  local opts = vim.tbl_deep_extend('force', defaults, user_opts or {})

  vim.filetype.add({
    pattern = {
      ['.*'] = function(path, buf)
        if not path or not buf or vim.bo[buf].filetype == 'bigfile' then return end
        if path ~= vim.fs.normalize(vim.api.nvim_buf_get_name(buf)) then return end
        local size = vim.fn.getfsize(path)
        if size <= 0 then return end
        if size > opts.size then return 'bigfile' end
        local lines = vim.api.nvim_buf_line_count(buf)
        return (size - lines) / lines > opts.line_length and 'bigfile' or nil
      end,
    },
  })

  vim.api.nvim_create_autocmd('FileType', {
    group = vim.api.nvim_create_augroup('vv-utils.bigfile', { clear = true }),
    pattern = 'bigfile',
    callback = function(ev)
      local ft = vim.filetype.match({ buf = ev.buf }) or ''
      if opts.notify then
        local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(ev.buf), ':p:~:.')
        local msg = ('Big file detected `%s`.\nSome Neovim features have been **disabled**.'):format(path)
        -- 启动期打开的大文件：FileType 先于 VimEnter 触发，此时 noice.nvim 尚未接管
        -- vim.notify，消息会退化成 nvim_echo。挂 VimEnter once 让 notify 走浮窗路径
        local function do_notify()
          vim.notify(msg, vim.log.levels.WARN, { title = 'Big File' })
        end
        if vim.v.vim_did_enter == 1 then
          do_notify()
        else
          vim.api.nvim_create_autocmd('VimEnter', { once = true, callback = do_notify })
        end
      end
      vim.api.nvim_buf_call(ev.buf, function()
        opts.setup({ buf = ev.buf, ft = ft })
      end)
    end,
  })
end

return M
