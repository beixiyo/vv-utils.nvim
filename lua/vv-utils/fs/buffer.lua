-- 文件移动后同步已加载 Neovim buffer 的路径

local M = {}

local function norm(path) return vim.fs.normalize(path) end

---@param old string
---@param new string
function M.sync_buffers(old, new)
  old = norm(old)
  new = norm(new)

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name == '' then goto continue end

      local normalized = norm(name)
      local target

      if normalized == old then
        target = new
      elseif normalized:sub(1, #old + 1) == old .. '/' then
        target = new .. normalized:sub(#old + 1)
      end

      if target and pcall(vim.api.nvim_buf_set_name, buf, target) then
        pcall(vim.api.nvim_buf_call, buf, function()
          vim.cmd('silent! doautocmd BufFilePost')
        end)
      end

      ::continue::
    end
  end
end

return M
