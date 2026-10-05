-- vv-utils.loading.mark — 在 buffer 指定 (row, col) 以 virt_text 渲染 loading 帧
--
-- 每帧清空本实例私有 namespace 后按 get_pos() 重画：宿主 set_lines 重写 buffer、
-- 目标行移动时不会在旧位置残留帧；get_pos() 返回 nil 即隐藏
-- buffer 被 wipe 时自动停止
--
-- 已知取舍：nvim_buf_attach 没有主动解除的 API，只能在 on_lines 回调里返回 true 解除；
-- 因此 stop 后监听要等该 buffer 下一次内容变化（或 buffer 被 wipe）才真正解除，
-- 期间闭包（handle / opts）驻留在 buffer 上。回调只做一次 is_active 判断，开销与驻留都很小，可以接受

local Handle = require('vv-utils.loading.handle')

local M = {}

--- 帧与 label 分段上色：帧（含前缀）用 hl，label 用 label_hl；后缀与 width 补齐的空格跟随帧
---@param opts VVLoadingMarkOpts
---@param frame string
---@param label string?
---@return [string, string][]
local function build_chunks(opts, frame, label)
  local chunks = { { opts.prefix .. frame, opts.hl } }
  local width = vim.fn.strdisplaywidth(chunks[1][1])
  if label and label ~= '' then
    local text = ' ' .. label
    chunks[#chunks + 1] = { text, opts.label_hl }
    width = width + vim.fn.strdisplaywidth(text)
  end

  local tail = opts.suffix
  width = width + vim.fn.strdisplaywidth(tail)
  if opts.width and opts.width > width then tail = tail .. string.rep(' ', opts.width - width) end
  if tail ~= '' then chunks[#chunks + 1] = { tail, opts.hl } end
  return chunks
end

---@param get_pos fun(): VVLoadingPos|VVLoadingPos[]|nil
---@return VVLoadingPos[]
local function positions(get_pos)
  local result = get_pos()
  if not result then return {} end
  if result.row then return { result } end
  return result
end

---@param opts VVLoadingMarkOpts 已归一化
---@param handle_opts vv-utils.loading.HandleSpec
---@return vv-utils.loading.Handle
function M.new(opts, handle_opts)
  local buf = opts.buf
  -- 每个实例用匿名 namespace：stop / 重画只清自己的 extmark，多个 mark 并存互不影响；
  -- 匿名 namespace 不进入 nvim_get_namespaces() 的具名表，不会随实例数无限增长
  local ns = vim.api.nvim_create_namespace('')

  handle_opts.render = function(frame, label)
    if not vim.api.nvim_buf_is_valid(buf) then return false end
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

    local line_count = vim.api.nvim_buf_line_count(buf)
    local chunks = build_chunks(opts, frame, label)
    for _, p in ipairs(positions(opts.get_pos)) do
      local row = p.row - 1
      if row >= 0 and row < line_count then
        local line_len = #(vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or '')
        local col = math.max(0, math.min(p.col or 0, line_len))
        pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, col, {
          virt_text = chunks,
          virt_text_pos = opts.pos,
          hl_mode = opts.hl_mode,
          priority = opts.priority,
        })
      end
    end
  end

  handle_opts.clear = function()
    if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1) end
  end

  local handle = Handle.new(handle_opts)
  if handle:is_active() and vim.api.nvim_buf_is_valid(buf) then
    local autocmd = vim.api.nvim_create_autocmd('BufWipeout', {
      buffer = buf,
      once = true,
      callback = function() handle:stop() end,
    })
    handle:on_stop(function() pcall(vim.api.nvim_del_autocmd, autocmd) end)

    -- 宿主 set_lines 整块重写时 extmark 会被挤走；内容变化后合并成一次 schedule 立即重画，
    -- 不等下一个时钟 tick（否则最长停留 interval_ms 在错误位置）
    -- stop 后要等 buffer 下一次变化，on_lines 返回 true 才解除监听（见文件头「已知取舍」）
    local pending = false
    vim.api.nvim_buf_attach(buf, false, {
      on_lines = function()
        if not handle:is_active() then return true end
        if pending then return end
        pending = true
        vim.schedule(function()
          pending = false
          handle:redraw()
        end)
      end,
    })
  end
  return handle
end

return M
