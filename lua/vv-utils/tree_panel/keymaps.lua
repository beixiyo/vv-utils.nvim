---@diagnostic disable: cast-local-type
-- Tree panel 的可选默认快捷键与帮助面板
--
-- tree panel 本身不主动注册快捷键；调用方显式调用 apply/apply_defaults 时才写入 panel buffer

local M = {}

---@type VVTreePanelMappings
local default_mappings = {
  j = 'next_item',
  ['<Down>'] = 'next_item',
  ['<C-n>'] = 'next_item',
  k = 'prev_item',
  ['<Up>'] = 'prev_item',
  ['<C-p>'] = 'prev_item',
  ['<CR>'] = 'open_node',
  ['<Tab>'] = 'toggle_node',
  l = 'open_node',
  ['<Right>'] = 'open_node',
  h = 'close_node',
  ['<Left>'] = 'close_node',
  zo = 'open_node',
  zc = 'close_node',
  za = 'toggle_node',
  zR = 'expand_all',
  zM = 'collapse_all',
  gf = 'jump',
  r = 'refresh',
  ['g?'] = 'help',
  q = 'close_panel',
  ['<Esc>'] = 'close_panel',
}

local help_actions = {
  next_item = { cat = 'Navigate' },
  prev_item = { cat = 'Navigate' },
  open_node = { cat = 'Navigate' },
  close_node = { cat = 'Navigate' },
  toggle_node = { cat = 'Navigate' },
  jump = { cat = 'Navigate' },
  expand_all = { cat = 'View' },
  collapse_all = { cat = 'View' },
  refresh = { cat = 'View' },
  help = { cat = 'View' },
  close_panel = { cat = 'View' },
}

local desc_prefix = 'vv-tree-panel: '

---@param panel VVTreePanel
---@param mappings VVTreePanelMappings
---@param opts? VVTreePanelKeymapOptions
function M.apply(panel, mappings, opts)
  assert(panel.buf and vim.api.nvim_buf_is_valid(panel.buf), 'tree panel buffer is not available')
  assert(type(mappings) == 'table', 'tree panel mappings must be a table')

  opts = opts or {}
  local keymap_opts = {
    buffer = panel.buf,
    silent = opts.silent == nil or opts.silent,
    nowait = opts.nowait == nil or opts.nowait,
  }

  for lhs, mapping in pairs(mappings) do
    if mapping ~= false then
      assert(type(lhs) == 'string' and lhs ~= '', 'tree panel mapping lhs must be a non-empty string')
      assert(type(mapping) == 'string' or type(mapping) == 'function' or type(mapping) == 'table',
        'tree panel mapping must be an action, callback, spec, or false')

      local target = mapping
      local desc
      if type(mapping) == 'table' then
        assert((mapping.action == nil) ~= (mapping.callback == nil),
          'tree panel mapping spec requires exactly one of action or callback')
        assert(mapping.desc == nil or type(mapping.desc) == 'string',
          'tree panel mapping desc must be a string')
---@diagnostic disable-next-line: cast-local-type
        target = mapping.action or mapping.callback
        desc = mapping.desc
      end
      if type(target) == 'string' then panel:_validate_action(target) end

      local callback
      if type(target) == 'function' then
        callback = function() target(panel:_action_context()) end
      else
        ---@cast target VVTreePanelAction
        callback = function() panel:execute(target) end
      end
      vim.keymap.set(opts.mode or 'n', lhs, callback, vim.tbl_extend('force', keymap_opts, {
        desc = desc_prefix .. (desc or (type(target) == 'string' and target or ('custom: ' .. lhs))),
      }))
    end
  end
end

---@param panel VVTreePanel
---@param overrides? VVTreePanelMappings
---@param opts? VVTreePanelKeymapOptions
function M.apply_defaults(panel, overrides, opts)
  ---@type VVTreePanelMappings
  local mappings = vim.deepcopy(default_mappings)
  for lhs, action in pairs(overrides or {}) do mappings[lhs] = action end
  M.apply(panel, mappings, opts)
end

---@param panel VVTreePanel
function M.open_help(panel)
  if panel.opts.help == false or not panel.buf or not vim.api.nvim_buf_is_valid(panel.buf) then return end

  local configured = type(panel.opts.help) == 'table' and panel.opts.help or {}
  local help_opts = vim.tbl_extend('force', {
    actions = help_actions,
    categories = { 'Navigate', 'View' },
    title = (panel.opts.title or panel.opts.id) .. ' keymaps',
    filetype = (panel.opts.filetype or 'vv-tree-panel') .. '-help',
  }, configured)
  help_opts.actions = vim.tbl_deep_extend('force', help_actions, configured.actions or {})
  help_opts.source_buf = panel.buf
  help_opts.desc_prefix = desc_prefix
  require('vv-utils.help_panel').open(help_opts)
end

return M
