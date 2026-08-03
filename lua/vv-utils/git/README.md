# `vv-utils.git`

## 职责

封装仓库定位、porcelain 状态、行级 diff 与共享装饰。所有异步 Git helper 都返回幂等 cancel，并会压制取消后已经排队的 Lua 回调

## 仓库与状态

`root(cwd)` 同步查根；`root_async(cwd, cb)` 异步查根。`git_dir_kind(dir)` 与 `is_linked_worktree(dir)` 用于识别普通仓库和 linked worktree

`tracked(root, cb, opts?)`、`index(root, cb, opts?)`、`ignored_entries(root, cb, opts?)` 都是异步接口。`index` 回传状态映射、忽略路径、`is_ignored` 函数及 `rename_map`；`parse_porcelain_z(data, root)` 与 `make_is_ignored(files, dirs)` 是可独立复用的纯解析工具

## 行级 diff

```lua
local cancel = require('vv-utils.git').diff_lines(path, function(markers)
  -- markers 已投影到 opts.side 指定的一侧
end, { from_rev = 'HEAD', to_rev = nil, side = 'new' })
```

`diff_lines(path, cb, opts?)` 获取单侧标记，`from_rev` / `to_rev` 可以指定任意 revision 范围，`side` 选择旧侧或新侧。`diff_line_sets(path, cb, opts?)` 同时获取 staged 与 unstaged，并把 staged 坐标映射至 worktree。`parse_diff_lines`、`parse_diff_hunks`、`map_index_markers` 可用于更底层的纯解析

## 装饰与边界

`symbol_for(xy)` 返回状态符号，`register_hl(augroup)` 注册共享高亮，`highlight_specs()` 返回可安全修改的基准副本。模块不维护调用方 UI 状态；取消只停止自身创建的 Git 进程与回调，不会取消调用方额外派生的工作
