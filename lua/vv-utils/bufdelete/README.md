# `vv-utils.bufdelete`

## 职责

在删除 buffer 时尽量维持现有窗口布局，避免直接 `:bdelete` 让侧栏或分屏出现不可预期的替换结果

## API

`delete(arg)` 删除指定目标；`all()` 删除全部普通 buffer；`other()` 删除除当前外的普通 buffer；`smart()` 根据当前窗口和 buffer 情况选择删除策略。`is_throwaway(buf)` 判断临时 buffer，`wipe_if_throwaway(buf)` 只在满足条件时清理。`replace_in_windows(buf)` 只把显示 `buf` 的窗口换成其它 buffer（优先 alternate，其次最近使用的 listed buffer，否则新建空 buffer），不删除 `buf`；窗口设了 `winfixbuf` 时抛 E1513，由调用方处理

## 边界

模块处理 buffer 与窗口关系，不替调用方保存修改、选择业务意义上的“当前文档”，也不定义哪些插件 buffer 应永久保留
