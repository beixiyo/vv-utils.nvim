# `vv-utils.format`

## 职责

处理中英文间距与行尾清理。纯文本函数可独立使用；buffer、项目与命令注册属于可选副作用，需显式启用

## 启用与命令

```lua
require('vv-utils').setup({
  format = { commands = true, punct = { '。' } },
})
```

启用后提供 `:VVAddSpaces`、`:VVCleanTrailing` 与 `:VVCleanTrailingProject`。后两个命令带范围；项目命令加 `!` 只预览不写入

## API

`add_spaces_around_english(text)` 只转换字符串。`clean_prose(text)` 识别散文与围栏代码；`clean_code(text)` 面向代码或配置行尾。`apply_to_buffer(transform, opts?)` 将文本变换应用到当前 buffer；`add_spaces(opts?)` 与 `clean_trailing(opts?)` 是便捷封装，支持 `range`、`silent`，后者还可 `force_full`

`clean_project(opts?)` 处理 Git tracked 的非二进制文本，返回 `{ scanned, changed, skipped_binary, files }`；`dry_run` 不写入，`include_untracked` 明确加入未跟踪且未忽略文件

## 配置边界

`prose_filetypes` 会与默认集合合并，`punct` 替换默认删除标点。项目级格式化依赖 Git；它不应被当作不受范围控制的全盘清理工具
