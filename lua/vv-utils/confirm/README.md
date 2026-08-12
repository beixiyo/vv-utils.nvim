# `vv-utils.confirm`

通用确认浮窗

调用方声明内容和确认回调，模块负责浮窗、语义高亮、buffer-local 键位与关闭生命周期

## 使用

```lua
require('vv-utils.confirm').open({
  title = 'Delete file?',
  message = 'This cannot be undone.',
  details = {
    { label = 'File', value = '/tmp/example.txt' },
  },
  severity = 'danger',
  confirm_label = 'Delete',
  on_confirm = function() delete_file() end,
})
```

## 内容

- `title`：必填，显示在边框上，使用 `Title` 高亮
- `message`：字符串、字符串数组或 `{ text, hl?, icon?, icon_hl? }` 数组
- `details`：`{ label, value, hl?, separator_before? }` 数组
- `severity`：`info`、`warn` 或 `danger`，只影响确认动作的高亮

`message`、detail label 和 detail value 中的换行都会拆成独立 buffer 行

detail value 的每一行保持缩进

## 操作

| 动作 | 默认按键 | footer 提示 | 回调 |
| --- | --- | --- | --- |
| 确认 | `Ctrl+y` | `Ctrl+y Confirm` | `on_confirm` |
| 取消 | `q`、`Esc`、`Ctrl+c`、`Enter`、`n` | `q Cancel` | `on_cancel` |

普通 `y` 和 `Y` 保留复制语义

`confirm_icon`、`confirm_label`、`confirm_hl`、`cancel_icon` 和 `cancel_label`
可覆盖 footer 展示

`open()` 返回 `{ close() }`。主动调用 `close()` 不触发任何回调，并且可以重复调用

## 自定义按键

`keys` 决定实际映射，`hint` 只决定 footer 展示

配置可通过 `vv-utils.setup()` 全局设置，也可在单次 `open()` 中覆盖

```lua
require('vv-utils').setup({
  confirm = {
    actions = {
      confirm = { keys = { '<C-y>', 'Y' }, hint = '<C-y>' },
      cancel = { keys = { 'q', '<Esc>', '<C-c>' }, hint = 'q' },
    },
  },
})

require('vv-utils.confirm').open({
  title = 'Delete file?',
  actions = { cancel = { hint = '<Esc>' } },
})
```

单次配置按动作字段合并，只覆盖 `hint` 不会丢失已有 `keys`

- `keys = false`：禁用该动作的全部内置映射
- `hint = false`：隐藏该动作的 footer
- 同一个键不能同时属于确认和取消动作

## 窗口

- 正文默认保留两列内边距
- 默认最大宽度为 96 列或编辑器宽度减 4
- 超长正文自动换行，窄窗口中的 footer 自动拆行
- 内容超过可用高度时，初始视口定位到 footer，并可向上滚动
- `window` 支持 `border`、`title_pos`、`min_width`、`max_width` 和 `zindex`
- `filetype` 默认为 `vv-confirm`

过小的 `max_width` 会根据 footer 中最宽的字符和内边距自动修正，避免宽 Unicode 图标溢出
