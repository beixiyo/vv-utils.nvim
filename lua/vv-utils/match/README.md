# `vv-utils.match`

将查询编译为可复用谓词，保证列表原有分组与顺序不被共享工具擅自改变

## 使用

```lua
local predicate, ok = require('vv-utils.match').compile(query, { mode = 'subseq' })
if ok then filtered = vim.tbl_filter(predicate, items) end
```

`compile(query, opts?)` 返回 `(predicate, ok)`；模式是字面子串 `'fixed'`、子序列 `'subseq'`、Vim 正则 `'regex'`，默认 `ignore_case = true`。正则非法时 `ok` 为 false，调用方可以保留旧结果或给出输入反馈。`next_mode(mode)` 轮换内置 `MODES`，`next_in(list, current)` 轮换宿主自定义模式列表

模块只判断命中，不评分、不排序，也不负责 UI 高亮
