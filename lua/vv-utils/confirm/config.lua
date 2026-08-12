-- 确认框动作配置：统一默认值、全局配置与单次覆盖的归一化

local M = {}

local defaults = {
  actions = {
    confirm = { keys = { '<C-y>' }, hint = '<C-y>' },
    cancel = { keys = { 'q', '<Esc>', '<C-c>', '<CR>', 'n' }, hint = 'q' },
  },
}

local configured = vim.deepcopy(defaults)

local function merge_action(base, override)
  local result = vim.deepcopy(base)
  if override == nil then return result end

  for key, value in pairs(override) do
    result[key] = vim.deepcopy(value)
  end
  return result
end

local function merge(base, override)
  override = override or {}
  local actions = override.actions or {}
  return {
    actions = {
      confirm = merge_action(base.actions.confirm, actions.confirm),
      cancel = merge_action(base.actions.cancel, actions.cancel),
    },
  }
end

local function normalize_keys(value, action)
  if value == false then return {} end
  if type(value) == 'string' then value = { value } end
  if type(value) ~= 'table' then
    error(('vv-utils.confirm: actions.%s.keys must be a string, list, or false'):format(action))
  end

  local result = {}
  local seen = {}

  for _, key in ipairs(value) do
    if type(key) ~= 'string' or key == '' then
      error(('vv-utils.confirm: actions.%s.keys must contain non-empty strings'):format(action))
    end

    local encoded = vim.keycode(key)
    if not seen[encoded] then
      seen[encoded] = true
      result[#result + 1] = key
    end
  end

  return result
end

local function normalize(config)
  for _, action in ipairs({ 'confirm', 'cancel' }) do
    local item = config.actions[action]
    item.keys = normalize_keys(item.keys, action)
    if item.hint ~= false and type(item.hint) ~= 'string' then
      error(('vv-utils.confirm: actions.%s.hint must be a string or false'):format(action))
    end
  end

  local confirm_keys = {}
  for _, key in ipairs(config.actions.confirm.keys) do
    confirm_keys[vim.keycode(key)] = key
  end

  for _, key in ipairs(config.actions.cancel.keys) do
    local conflict = confirm_keys[vim.keycode(key)]
    if conflict then
      error(('vv-utils.confirm: key %s is assigned to both confirm and cancel'):format(conflict))
    end
  end

  return config
end

---@param opts? VVConfirmConfig
function M.setup(opts)
  configured = normalize(merge(defaults, opts))
end

---@param actions? VVConfirmActionsConfig
---@return VVConfirmConfig
function M.resolve(actions)
  return normalize(merge(configured, { actions = actions }))
end

---@return VVConfirmConfig
function M.get()
  return vim.deepcopy(configured)
end

return M
