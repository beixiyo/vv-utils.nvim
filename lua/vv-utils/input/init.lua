-- vv-utils.input — 声明式输入字段装饰原语
--
-- 只负责 label / placeholder 的 extmark 渲染，不持有字段状态，也不管理
-- buffer、window、焦点或输入生命周期。调用方传入上次返回的 extmark id，
-- 即可原位更新同一个字段

local M = {}

---@alias VVInputChunk [string, string?]

---@param lhs string
---@return string
function M.display_key(lhs)
  local keys = vim.api.nvim_replace_termcodes(lhs, true, true, true)
  local label = vim.fn.keytrans(keys):gsub('<NL>', '^J')
  return label
end

---@param icon? string
---@param key? string
---@param label? string
---@return string?
function M.action_hint(icon, key, label)
  if not key or key == '' then return nil end

  local parts = {}
  if icon and icon ~= '' then parts[#parts + 1] = icon end
  parts[#parts + 1] = key
  if label and label ~= '' then parts[#parts + 1] = label end
  return table.concat(parts, ' ')
end

---@param value string|VVInputChunk[]?
---@return VVInputChunk[]?
local function chunks(value)
  if type(value) == 'string' then
    if value == '' then return nil end
    return { { value } }
  end
  if type(value) == 'table' and #value > 0 then return value end
end

---@param buf integer
---@param namespace integer
---@param id integer?
local function delete_extmark(buf, namespace, id)
  if id then pcall(vim.api.nvim_buf_del_extmark, buf, namespace, id) end
end

---@param opts VVInputRenderOpts
---@return VVInputRenderResult
function M.render(opts)
  local label_row = opts.label_row or opts.input_row
  local label_chunks = chunks(opts.label_chunks)
  local placeholder = chunks(opts.placeholder)
  local right_gravity = opts.right_gravity == true
  local label_id = opts.label_id
  local placeholder_id = opts.placeholder_id

  if label_chunks then
    local decoration
    if opts.label_position == 'above' then
      decoration = {
        id = label_id,
        virt_lines = { label_chunks },
        virt_lines_above = true,
        right_gravity = right_gravity,
      }
    else
      decoration = {
        id = label_id,
        virt_text = label_chunks,
        virt_text_pos = 'overlay',
        right_gravity = right_gravity,
      }
    end
    label_id = vim.api.nvim_buf_set_extmark(
      opts.buf,
      opts.namespace,
      label_row,
      0,
      decoration
    )
  else
    delete_extmark(opts.buf, opts.namespace, label_id)
    label_id = nil
  end

  local line = vim.api.nvim_buf_get_lines(
    opts.buf,
    opts.input_row,
    opts.input_row + 1,
    false
  )[1] or ''
  if line == '' and placeholder then
    placeholder_id = vim.api.nvim_buf_set_extmark(
      opts.buf,
      opts.namespace,
      opts.input_row,
      0,
      {
        id = placeholder_id,
        virt_text = placeholder,
        virt_text_pos = 'overlay',
        right_gravity = right_gravity,
      }
    )
  else
    delete_extmark(opts.buf, opts.namespace, placeholder_id)
    placeholder_id = nil
  end

  return {
    label_id = label_id,
    placeholder_id = placeholder_id,
  }
end

---@class VVInputRenderOpts
---@field buf integer
---@field namespace integer
---@field input_row integer
---@field label_row? integer @default input_row
---@field label_chunks? VVInputChunk[]
---@field label_position? 'overlay'|'above' @default 'overlay'
---@field placeholder? string|VVInputChunk[]
---@field label_id? integer
---@field placeholder_id? integer
---@field right_gravity? boolean @default false

---@class VVInputRenderResult
---@field label_id? integer
---@field placeholder_id? integer

return M
