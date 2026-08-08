# `vv-utils.fs`

## 职责

提供文件、路径、buffer 同步和多文件事务的底层原语。简单操作与事务 API 分开：前者直接执行，后者用于需要快照校验和补偿回滚的编辑流程

## API

| 分类 | 函数 |
|---|---|
| 路径 | `exists(path)`、`realpath(path)`、`unique_dest(destination)` |
| 文件操作 | `mkdir_p(directory)`、`create_file(file)`、`delete(target)`、`rename(source, destination)`、`copy(source, destination)` |
| 内容 | `read_all(file)`、`write_all(file, content, opts?)`、`load_json(source, opts?)`、`save_json(file, data, opts?)` |
| 编辑器 | `sync_buffers(old, new)`，把已打开的 buffer 与文件移动保持一致 |
| 文件识别 | `inspect_file(path, opts?)`、`is_binary(path, opts?)`、`file_info_lines(info, opts?)`、`format_size(bytes)`、`highlight_file_info(buf)` |
| 目录统计 | `inspect_dir(path)`、`scan_dir(path, opts?)`、`dir_info_lines(info, opts?)` |
| 事务 | `new_transaction(opts)` |

`inspect_file()` / `is_binary()` 基于内容判断，适合在展示或批量处理前跳过二进制文件；不是按扩展名猜测

## 目录统计边界

`inspect_dir()` 是同步的，但只读直接子项，成本与目录宽度成正比，可以直接在光标移动这类高频路径上调用

`scan_dir()` 是递归的，成本与目录下的 inode 总数成正比，**必须当成长任务对待**。它用显式 DFS 栈保存 scandir 句柄，每处理一个 entry 检查一次预算（默认 `2000` entries 或 `8ms`），超预算就让出到下一个事件循环，因此单片占用可控而不是一次跑完：

```lua
local handle = Fs.scan_dir(path, {
  max_entries = 200000,
  on_progress = function(result) render(result) end,   -- result.done == false
  on_done = function(result) render(result) end,
})

handle.cancel()   -- 幂等；取消后不再触发任何回调
```

分片之间用 uv timer 让出，**不能改成 `vim.schedule` 自递归**：schedule 队列在同一次事件循环批次里被排空，新排入的回调会被接着执行，分片就退化成忙循环——单片耗时看着依然很小，主线程却从头到尾没还给编辑器（实测 89 万文件的目录连续占用 5.9s，改用 timer 后单次占用降到 18ms）。[目录统计测试](../../../tests/test_fs_dir_info.lua) 用 uv idle 的迭代计数守住这条

四条语义值得在接入前确认：

- 不跟随 symlink，只按 scandir 返回的 entry type 决定是否递归，因此指向祖先目录的链接不会成环
- 不做任何过滤，统计的是磁盘真实占用，口径与 `du` 一致
- 达到 `max_entries` 时以 `truncated = true` 结束，`on_done` 仍会触发。调用方必须把它渲染成「至少这么多」而不是最终值——`dir_info_lines()` 已经这样处理

`dir_info_lines()` 对未完成和已截断的扫描会拼上 `file_info_highlight.markers` 里的状态标记，`highlight_file_info()` 据此把中间值高亮成独立分组，避免被误读成结果

## 事务边界

`new_transaction()` 的实例会记录文件快照，在真正写入前重验快照，失败后执行补偿回滚，并保留一层成功事务的撤回能力。它适合 WorkspaceEdit 或批量重命名等需要原子语义的流程；普通单文件读写不应为了形式统一而套事务
