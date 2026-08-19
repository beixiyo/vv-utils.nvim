-- 可复用的 Trouble 风格树形侧栏
--
-- 数据、渲染和行为均由调用方注入，模块只管理折叠状态、窗口与预览生命周期

local Keymaps = require('vv-utils.tree_panel.keymaps')
local Lifecycle = require('vv-utils.tree_panel.lifecycle')
local Model = require('vv-utils.tree_panel.model')
local Renderer = require('vv-utils.tree_panel.renderer')
local Syntax = require('vv-utils.tree_panel.syntax')
local Toolbar = require('vv-utils.tree_panel.toolbar')

local M = {}
require('vv-utils.tree_panel.types')

---@class VVTreePanel
---@field opts VVTreePanelOptions
---@field nodes VVTreePanelNode[]
---@field folded table<string, boolean>
---@field rows table<integer, VVTreePanelRow>
---@field buf? integer
---@field win? integer
---@field ns? integer
---@field source_win? integer
---@field file_preview? VVTreePanelFilePreview
---@field preview_cursor? fun()
---@field cancel_preview? fun()
---@field save_width_debounced? fun()
---@field cancel_width_save? fun()
---@field current_width? integer
---@field saved_width? integer
---@field lifecycle_group? integer
---@field toolbar_win? integer
---@field toolbar_buf? integer
---@field toolbar_ns? integer
---@field toolbar_group? integer
local Panel = {}
Panel.__index = Panel
local actions

---@param opts VVTreePanelOptions
---@return VVTreePanel
function M.new(opts)
  assert(type(opts) == 'table', 'tree panel options are required')
  assert(type(opts.id) == 'string' and opts.id ~= '', 'tree panel id is required')
  assert(type(opts.source) == 'function', 'tree panel source callback is required')
  assert(opts.on_attach == nil or type(opts.on_attach) == 'function',
    'tree panel on_attach must be a function')
  if opts.state then
    assert(type(opts.state) == 'table'
        and type(opts.state.get) == 'function'
        and type(opts.state.set) == 'function',
      'tree panel state must be a VVStateHandle')
  end

  return setmetatable({
    opts = opts,
    nodes = {},
    folded = {},
    rows = {},
  }, Panel)
end

---@param panel VVTreePanel
---@param mappings VVTreePanelMappings
---@param opts? VVTreePanelKeymapOptions
function M.apply_mappings(panel, mappings, opts)
  Keymaps.apply(panel, mappings, opts)
end

--- 将独立源码转换为 Tree-sitter 高亮 chunks；解析失败时自动退回 fallback 高亮
---@param text string
---@param lang string?
---@param fallback_hl? string
---@return VVTreePanelChunk[]
function M.syntax_chunks(text, lang, fallback_hl)
  return Syntax.chunks(text, lang, fallback_hl)
end

---@param panel VVTreePanel
---@param overrides? VVTreePanelMappings
---@param opts? VVTreePanelKeymapOptions
function M.apply_default_mappings(panel, overrides, opts)
  Keymaps.apply_defaults(panel, overrides, opts)
end

---@return boolean
function Panel:is_open()
  return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

---@return integer
function Panel:_initial_width()
  if self.opts.state then
    local loaded = self.opts.state:get('width')
    if type(loaded) == 'number' and loaded > 0 then return math.floor(loaded) end
  end

  if self.current_width then return self.current_width end
  return self.opts.width or 52
end

---@return integer?
function Panel:_remember_width()
  if not self:is_open() then return self.current_width end

  local width = vim.api.nvim_win_get_width(self.win)
  self.current_width = width
  return width
end

function Panel:_save_width()
  local width = self:_remember_width()
  if not self.opts.state or not width or width == self.saved_width then return end
  if self.opts.state:set('width', width) then self.saved_width = width end
end

---@return integer?
function Panel:get_width()
  if self:is_open() then return vim.api.nvim_win_get_width(self.win) end
  return self.current_width
end

---@return VVTreePanelRow?
function Panel:_cursor_row()
  if not self:is_open() then return nil end
  return self.rows[vim.api.nvim_win_get_cursor(self.win)[1]]
end

---@param row VVTreePanelRow
---@return VVTreePanelRenderRow|string
function Panel:_render_node(row)
  local node = row.node
  local has_children = node.children and #node.children > 0 or false
  local folded = self.folded[node.id]
  if folded == nil then folded = node.expanded == false end

  local ctx = {
    panel = self,
    node = node,
    depth = row.depth,
    folded = folded,
    has_children = has_children,
  }
  if self.opts.render and self.opts.render.node then return self.opts.render.node(ctx) end

  local indent = string.rep('  ', row.depth)
  local marker = has_children and (folded and ' ' or ' ') or '  '
  return {
    chunks = {
      { indent .. marker, 'Comment' },
      { node.label or node.id, node.selectable == false and 'Comment' or 'Normal' },
    },
  }
end

function Panel:render()
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then return end

  Toolbar.render(self)

  local cursor_line
  local cursor_id
  if self:is_open() then
    cursor_line = vim.api.nvim_win_get_cursor(self.win)[1]
    local cursor_row = self.rows[cursor_line]
    cursor_id = cursor_row and cursor_row.node.id or nil
  end

  self.nodes = self.opts.source({ panel = self }) or {}
  local visible = Model.flatten(self.nodes, self.folded)
  local output = {}
  local line_rows = {}
  local render = self.opts.render or {}

  if self:is_open() and render.winbar ~= nil then
    local row
    if render.winbar ~= false then
      row = render.winbar({ panel = self, count = #visible })
    end
    vim.wo[self.win].winbar = Renderer.statusline(row)
  end

  if render.header then
    output[#output + 1] = render.header({ panel = self, count = #visible })
  elseif self.opts.title then
    output[#output + 1] = { text = self.opts.title, hl = 'Title' }
  end
  if #visible == 0 then
    output[#output + 1] = render.empty and render.empty({ panel = self }) or { text = 'No items', hl = 'Comment' }
  else
    for _, row in ipairs(visible) do
      output[#output + 1] = self:_render_node(row)
      line_rows[#output] = row
    end
  end
  if render.footer then output[#output + 1] = render.footer({ panel = self, count = #visible }) end
  if #output == 0 then output[1] = { text = '' } end

  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, {})
  vim.api.nvim_buf_clear_namespace(self.buf, self.ns, 0, -1)
  for line, row in ipairs(output) do Renderer.set_line(self.buf, self.ns, line - 1, row) end
  vim.bo[self.buf].modifiable = false

  self.rows = line_rows

  if self:is_open() and cursor_line then
    local target_line
    if cursor_id then
      for line, candidate in pairs(self.rows) do
        if candidate.node.id == cursor_id then
          target_line = line
          break
        end
      end
    end
    target_line = target_line or math.min(cursor_line, #output)
    vim.api.nvim_win_set_cursor(self.win, { math.max(1, target_line), 0 })
  end
end

function Panel:_toggle()
  local row = self:_cursor_row()
  if not row then return end

  local node = row.node
  if node.children and #node.children > 0 then
    local folded = self.folded[node.id]
    if folded == nil then folded = node.expanded == false end
    self.folded[node.id] = not folded
    self:render()
    return
  end

  self:_open()
end

function Panel:_open_fold()
  local row = self:_cursor_row()
  if not row then return end
  if row.node.children and #row.node.children > 0 then
    self.folded[row.node.id] = false
    self:render()
  else
    self:_open()
  end
end

---@param delta -1|1
function Panel:_move(delta)
  if not self:is_open() then return end

  local lines = {}
  for line in pairs(self.rows) do lines[#lines + 1] = line end
  table.sort(lines)

  local current = vim.api.nvim_win_get_cursor(self.win)[1]
  local target = Model.move_target(lines, current, delta, vim.v.count1)
  if target then vim.api.nvim_win_set_cursor(self.win, { target, 0 }) end
end

function Panel:_close_fold()
  local row = self:_cursor_row()
  if not row then return end

  if row.node.children and #row.node.children > 0 and self.folded[row.node.id] ~= true then
    self.folded[row.node.id] = true
    self:render()
    return
  end

  if row.parent then
    self.folded[row.parent.id] = true
    local parent_id = row.parent.id
    self:render()
    self:_focus_node(parent_id)
  end
end

---@param id string
---@return boolean
function Panel:_focus_node(id)
  if not self:is_open() then return false end
  for line, candidate in pairs(self.rows) do
    if candidate.node.id == id then
      vim.api.nvim_win_set_cursor(self.win, { line, 0 })
      return true
    end
  end
  return false
end

function Panel:_preview_cursor()
  local row = self:_cursor_row()
  if not row or row.node.selectable == false then return end

  local ctx = { panel = self, node = row.node, depth = row.depth }
  if self.opts.preview then
    self.opts.preview(row.node, ctx)
  elseif self.file_preview then
    self.file_preview:show(row.node.location)
  end
end

---@param close_panel boolean
function Panel:_activate(close_panel)
  local row = self:_cursor_row()
  if not row or row.node.selectable == false then return end

  local ctx = { panel = self, node = row.node, depth = row.depth }
  local restore_width = self:is_open() and vim.api.nvim_win_get_width(self.win) or nil
  if not close_panel and self.opts.open then
    self.opts.open(row.node, ctx)
  elseif self.opts.jump then
    self.opts.jump(row.node, ctx)
  elseif self.file_preview then
    self.file_preview:jump(row.node.location)
  end

  if restore_width and self:is_open()
      and vim.api.nvim_win_get_width(self.win) ~= restore_width
  then
    vim.api.nvim_win_set_width(self.win, restore_width)
  end
  if close_panel then self:close() end
end

function Panel:_open()
  self:_activate(false)
end

function Panel:_jump()
  self:_activate(true)
end

function Panel:_help()
  Keymaps.open_help(self)
end

---@return VVTreePanelRenderContext
function Panel:_action_context()
  local row = self:_cursor_row()
  return {
    panel = self,
    node = row and row.node or nil,
    depth = row and row.depth or nil,
  }
end

---@param action string
function Panel:_validate_action(action)
  assert(actions[action], 'unknown tree panel action: ' .. action)
end

actions = {
  next_item = function(panel) panel:_move(1) end,
  prev_item = function(panel) panel:_move(-1) end,
  toggle_node = function(panel) panel:_toggle() end,
  open_node = function(panel) panel:_open_fold() end,
  close_node = function(panel) panel:_close_fold() end,
  jump = function(panel) panel:_jump() end,
  expand_all = function(panel)
    Model.fold_all(panel.nodes, panel.folded, false)
    panel:render()
  end,
  collapse_all = function(panel)
    Model.fold_all(panel.nodes, panel.folded, true)
    panel:render()
  end,
  refresh = function(panel)
    if panel.opts.on_refresh then
      panel.opts.on_refresh({ panel = panel })
    else
      panel:refresh()
    end
  end,
  help = function(panel) panel:_help() end,
  close_panel = function(panel) panel:close() end,
}

---@param action VVTreePanelAction
function Panel:execute(action)
  local handler = actions[action]
  if not handler then error('unknown tree panel action: ' .. tostring(action)) end
  handler(self)
end

function Panel:open()
  if self:is_open() then
    vim.api.nvim_set_current_win(self.win)
    return
  end

  local ok, err = xpcall(function() Lifecycle.open(self) end, debug.traceback)
  if ok then return end

  Lifecycle.rollback(self)
  error(err, 0)
end

function Panel:close()
  if self:is_open() then
    self:_save_width()
    vim.api.nvim_win_close(self.win, true)
  end
end

function Panel:toggle()
  if self:is_open() then
    self:close()
  else
    self:open()
  end
end

function Panel:refresh()
  self:render()
end

return M
