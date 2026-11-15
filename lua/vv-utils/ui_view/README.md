# `vv-utils.ui_view`

居中浮窗里的列表界面：顶部标签栏、分组加计数、可展开详情、页脚按键提示，内容可反复刷新。调用方只描述「这一页有哪些分组和条目」和按键动作，窗口、背景遮罩、终端缩放后的重排、行号与条目的对应、重绘后的光标位置都由模块负责

适合插件管理、任务列表、回收站这类「浮窗里一份可操作的清单」。侧栏树用 [`tree_panel`](../tree_panel/README.md)，一次性确认框用 [`modal`](../modal/README.md)

## 使用

```lua
local view = require('vv-utils.ui_view').open({
  brand = 'Pack',
  tabs = {
    { id = 'plugins', label = 'Plugins', key = '1' },
    { id = 'stats', label = 'Stats', key = '2' },
  },
  page = function(view)
    return {
      header = { { { '共 ', 'Comment' }, { '12', 'Number' } } },
      sections = {
        {
          id = 'enabled',
          title = 'Enabled',
          items = {
            {
              id = 'telescope',
              row = { chunks = { { '● ', 'String' }, { 'telescope' } }, virt_text = { { 'lazy', 'Comment' } } },
              detail = function() return { 'https://github.com/…', '依赖 plenary' } end,
            },
          },
        },
      },
      empty = '没有内容',
    }
  end,
  actions = {
    { key = { 'x', '<Space>' }, desc = 'Toggle', tab = 'plugins', run = function(view, item)
      if item then toggle(item.id) end
      view.refresh()
    end },
  },
})
```

`page(view)` 每次刷新都会调用，返回当前标签的内容；用 `view.tab()` 区分标签。行可以是字符串、片段数组，或带 `virt_text` 的 [`ui_rows`](../ui_rows/) 行。列对齐、截断、比例条用 `ui_rows.table` / `truncate` / `bar`

## 行为

| 项 | 说明 |
|---|---|
| 刷新 | `view.refresh()` 整页重写，按条目 `id` 恢复光标；条目上方插入、删除内容后光标仍跟着原条目，落在详情行上也保持 |
| 展开 | 条目带 `detail` 时 `expand_key`（默认 `<CR>`）切换；`detail` 为函数时展开才求值。从详情行收起回到条目本身 |
| 标签 | `<Tab>` / `<S-Tab>` 轮换，`tab.key` 直达，鼠标点击标签切换；切换后回到顶部 |
| 动作 | `actions[].run(view, item)` 拿到光标所在条目；`tab` 限定动作只在某些标签下生效，页脚提示随标签变化；多个键共用一个动作时页脚只显示第一个，`hint = 'all'` 全部显示 |
| 导航 | `]]` / `[[` 在分组之间跳转；`section_keys = false` 关闭 |
| 关闭 | `close_keys`（默认 `q`、`<Esc>`）；`:q` 等外部方式关闭同样触发 `on_close`，只触发一次 |
| 缩放 | 终端尺寸变化后窗口重新居中并重绘，`page` 里按 `nvim_win_get_width(view.win)` 算列宽即可 |
| 尺寸 | 默认占编辑器的 0.8；`width = 'content'` / `height = 'content'` 按内容与页脚提示定尺寸，每次刷新后重排，`min_width` 兜底 |
| 标题 | `page` 返回的 `title` 每次刷新写到边框上，用来显示会变化的统计 |
| 光标 | 落在条目内容的起始列而不是缩进里；没有条目时自动关掉当前行高亮 |

内置键只在没被 `actions` 占用时才绑定。映射的 `desc` 为 `<desc_prefix>: <动作>`，可交给 [`help_panel`](../help_panel/README.md) 反读

进行中的条目用 [`loading.mark`](../loading/README.md) 加 spinner，`get_pos` 里用 `view.pos_of(id)` 回查行号与内容起始列，整页重绘不会让动画错位

## 高亮组

都 link 到标准组，跟随主题：

| 组 | 默认 link | 用途 |
|---|---|---|
| `VVViewBrand` | `IncSearch` | 标签栏左侧的界面名 |
| `VVViewTab` / `VVViewTabActive` | `CursorLine` / `Visual` | 标签与当前标签的底色 |
| `VVViewTabKey` | `Special` | 标签上的键位，叠在标签底色上 |
| `VVViewSection` / `VVViewCount` | `Title` / `Comment` | 分组标题与计数 |
| `VVViewDetailKey` / `VVViewDetailValue` | `Comment` / `String` | 详情里的属性名与值，供调用方使用 |
| `VVViewMuted` | `Comment` | 次要文字，供调用方使用 |

配置项与句柄方法的完整类型见 [types.lua](types.lua)
