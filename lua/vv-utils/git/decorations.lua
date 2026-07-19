-- Git 状态装饰：共享高亮与 porcelain 状态符号

local M = {}

-- VSCode Dark+ gitDecoration.* 调色板（所有 git 状态色的单一真相来源）
-- 通过 M.register_hl() 批量注册，vv-explorer / vv-git / 其它 vendor 统一 link 过来
local HL_SPECS = {
  VVGitAdded     = { fg = '#81b88b' }, -- staged A：灰绿
  VVGitModified  = { fg = '#e2c08d' }, -- M：黄
  VVGitDeleted   = { fg = '#c74e39' }, -- D：红
  VVGitRenamed   = { fg = '#4ec9b0' }, -- R/C：青绿（与 Added 灰绿、Untracked 亮绿拉开区分）
  VVGitUntracked = { fg = '#73c991' }, -- ?：亮绿
  VVGitConflict  = { fg = '#e4676b', bold = true },
  VVGitIgnored   = { link = 'Comment' },
}

-- 批量注册 VVGit* 高亮组（自带 default=true + ColorScheme 重挂）
---@param augroup? string  默认 'vv-utils.git.hl'
function M.register_hl(augroup)
  require('vv-utils.hl').register(augroup or 'vv-utils.git.hl', HL_SPECS)
end

-- porcelain XY → {glyph, hl}。hl 统一走 `VVGit*`（vendor-neutral）
-- 调用方需在 setup 里调一次 M.register_hl()，否则组不存在会 fallback 到 Normal
-- 不在表里的给 'M' 默认
local SYMBOLS = {
  ['??'] = { glyph = 'U', hl = 'VVGitUntracked' },
  ['A '] = { glyph = 'A', hl = 'VVGitAdded' },
  ['AM'] = { glyph = 'A', hl = 'VVGitAdded' },
  ['M '] = { glyph = 'M', hl = 'VVGitModified' },
  [' M'] = { glyph = 'M', hl = 'VVGitModified' },
  ['MM'] = { glyph = 'M', hl = 'VVGitModified' },
  ['AD'] = { glyph = 'D', hl = 'VVGitDeleted' },
  ['D '] = { glyph = 'D', hl = 'VVGitDeleted' },
  [' D'] = { glyph = 'D', hl = 'VVGitDeleted' },
  ['R '] = { glyph = 'R', hl = 'VVGitRenamed' },
  [' R'] = { glyph = 'R', hl = 'VVGitRenamed' },
  ['C '] = { glyph = 'C', hl = 'VVGitRenamed' }, -- copied，VSCode 视觉同 renamed
  [' C'] = { glyph = 'C', hl = 'VVGitRenamed' },
  ['UU'] = { glyph = '!', hl = 'VVGitConflict' },
  ['AA'] = { glyph = '!', hl = 'VVGitConflict' },
  ['DD'] = { glyph = '!', hl = 'VVGitConflict' },
}

---@param xy string?
---@return {glyph:string, hl:string}?
function M.symbol_for(xy)
  if not xy then return nil end
  return SYMBOLS[xy] or { glyph = 'M', hl = 'VVGitModified' }
end

return M
