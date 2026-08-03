# `vv-utils.input`

为调用方持有的输入 buffer 渲染 label、placeholder 与操作提示，而不接管窗口、焦点、值或编辑生命周期

## 使用

```lua
ids = require('vv-utils.input').render({
  buf = buf, namespace = ns, input_row = 0,
  label_chunks = { { 'Filter', 'Title' } }, placeholder = '输入筛选条件',
})
```

`render(opts)` 需要 `buf`、`namespace`、`input_row`，可设置 label 行、`label_chunks`、`placeholder`、`label_position = 'overlay'|'above'`、已有 extmark ID 与 `right_gravity`。返回 `{ label_id, placeholder_id }`，下次渲染应复用它们以避免残留 mark

`display_key(lhs)` 统一展示键位；`action_hint(icon, key, label)` 构造高亮提示 chunks。模块只产生 extmark 表示层，输入内容是否为空、何时刷新均由宿主控制
