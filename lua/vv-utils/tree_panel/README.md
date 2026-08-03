# `vv-utils.tree_panel`

## 职责

可复用的 Trouble 风格树形侧栏。模块管理窗口、折叠、预览与宽度生命周期；调用方提供节点、渲染、映射和打开策略，因此不会把具体插件业务写进底层

## 最小示例

```lua
local TreePanel = require('vv-utils.tree_panel')
local panel = TreePanel.new({
  id = 'references',
  width = 52,
  state = require('vv-utils.state').register('my-plugin', 'references'),
  source = function() return nodes end,
  on_attach = function(current)
    TreePanel.apply_default_mappings(current, { q = false, x = 'close_panel' })
  end,
  render = {
    header = function() return { text = 'References', hl = 'Title' } end,
    node = function(ctx) return { text = ctx.node.label } end,
  },
})
panel:toggle()
```

## API 与契约

`new(opts)` 要求非空 `id` 与 `source()`，可选 `state`（需有 `get` / `set`）保存宽度。实例提供 `open()`、`close()`、`toggle()`、`refresh()`、折叠与跳转操作；窗口是否存在可用 `is_open()` 判断

`apply_mappings(panel, mappings, opts?)` 只安装显式动作表。`apply_default_mappings(panel, overrides?, opts?)` 才安装通用键位：`j`/`k`/`C-n`/`C-p` 预览移动、`h`/`l` 树导航、`Enter` 打开、`gf` 打开后关闭、`g?` 帮助。`syntax_chunks(text, lang, fallback_hl?)` 为独立文本生成 Tree-sitter chunks

渲染完全由 `render.header`、`node`、`empty`、`footer`、`winbar` 决定，均可返回纯文本或高亮 chunks；`winbar = false` 清空固定顶部栏。模块本身不强加 keymap，也不拥有节点数据
