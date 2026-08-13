# `vv-utils.help_panel`

从现有 buffer-local keymap 反向生成帮助浮窗，避免维护一份容易过期的静态按键表

## 使用

```lua
require('vv-utils.help_panel').open({
  source_buf = buf,
  desc_prefix = 'references:',
  title = 'References',
})
```

`open(opts)` 需要 `source_buf` 与 `desc_prefix`，只收集 `desc` 匹配前缀的映射。`actions` 为动作名提供分类、`icon` 与可选的 `icon_hl`，`categories` 控制分组顺序；未声明分类会归入 Other。`extra_rows` 可加入不来自 keymap 的提示，如 prompt 自己的按键，并同样支持 `icon_hl`。`title`、`title_icon`、`title_icon_hl`、`filetype` 用于展示定制

模块只读取映射并渲染，不注册、修改或推断业务动作；调用方的 keymap `desc` 是文档来源
