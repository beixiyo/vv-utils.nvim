-- Git 领域 facade：聚合仓库、状态、差异与装饰能力

local decorations = require('vv-utils.git.decorations')
local diff = require('vv-utils.git.diff')
local repository = require('vv-utils.git.repository')
local status = require('vv-utils.git.status')

return {
  git_dir_kind = repository.git_dir_kind,
  is_linked_worktree = repository.is_linked_worktree,
  root = repository.root,
  root_async = repository.root_async,

  parse_porcelain_z = status.parse_porcelain_z,
  make_is_ignored = status.make_is_ignored,
  tracked = status.tracked,
  index = status.index,
  ignored_entries = status.ignored_entries,

  parse_diff_lines = diff.parse_diff_lines,
  parse_diff_hunks = diff.parse_diff_hunks,
  map_index_markers = diff.map_index_markers,
  diff_line_sets = diff.diff_line_sets,
  diff_lines = diff.diff_lines,

  register_hl = decorations.register_hl,
  symbol_for = decorations.symbol_for,
}
