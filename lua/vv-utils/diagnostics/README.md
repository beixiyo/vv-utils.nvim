# `vv-utils.diagnostics`

## 职责

将 Neovim 诊断转换为适合树、列表和状态栏消费的轻量数据，而不干预诊断生产、显示或更新时机

## API

`collect_by_path()` 聚合已加载 buffer，得到按路径与 severity 分类的计数。`symbol_for(counts)` 选取最高 severity 对应的符号与 `Diagnostic*` 高亮；未安装 `vv-icons` 时回退字母。`format_range(buf, l1, l2?)` 返回指定行范围内的用户可读诊断文本

## 边界

返回结果是快照，不自动订阅 LSP 或缓存失效。调用方应在自己的刷新周期中重新收集，并决定如何合并未加载文件的诊断
