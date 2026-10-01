# `vv-utils.fs`

## 职责

提供文件、路径、buffer 同步和多文件事务的底层原语。简单操作与事务 API 分开：前者直接执行，后者用于需要快照校验和补偿回滚的编辑流程

## API

| 分类 | 函数 |
|---|---|
| 路径 | `exists(path)`、`is_directory(path)`、`is_dir_empty(path)`、`realpath(path)`、`unique_dest(destination)` |
| 文件操作 | `mkdir_p(directory)`、`create_file(file)`、`delete(target)`、`rename(source, destination)`、`copy(source, destination)` |
| 内容 | `read_all(file)`、`write_all(file, content, opts?)`、`load_json(source, opts?)`、`save_json(file, data, opts?)` |
| 临时文件 | `temp.write(content, opts?)`、`temp.create(opts?)`、`temp.cleanup(paths)` |
| 编辑器 | `sync_buffers(old, new)`，把已打开的 buffer 与文件移动保持一致：改名后，**未修改**的 buffer 重读磁盘文件清除 notedited，之后可直接 `:w`；**已修改**的 buffer 只改名、绝不重读，对已存在的目标 `:w` 仍报 E13，调用方需用 `write!`。边界见下节 |
| 事务 | `new_transaction(opts)` |

文件与目录信息按职责使用独立模块

- `vv-utils.fs.file_probe`：`inspect(path, opts?)`、`is_binary(path, opts?)`
- `vv-utils.fs.file_render`：`lines(info, opts?)`、`format_size(bytes)`
- `vv-utils.fs.dir_scan`：`shallow(path)`、`scan(path, opts?)`
- `vv-utils.fs.dir_render`：`lines(info, opts?)`
- `vv-utils.fs.file_info_highlight`：`apply(buf)`

`file_probe` 基于内容判断，适合在展示或批量处理前跳过二进制文件；不是按扩展名猜测

`write_all()` 的 `mode` 控制新文件权限，`directory_mode` 控制新建父目录权限；已有文件和目录保持原权限

`temp.write()` 和 `temp.create()` 使用独占创建，默认权限为 `0600`；调用方持有返回路径，并用幂等的 `temp.cleanup()` 清理自己的文件

`is_directory()` 跟随软链接；`is_dir_empty()` 只读取第一个目录成员，路径不是目录或无法读取时返回 `nil, error_message`

## sync_buffers 边界

`nvim_buf_set_name` 会让 buffer 带上 notedited，对已存在的文件 `:write` 报 E13。实测能清除它的只有两种办法：重新读取文件（`:edit!`），或 `:write!`（但它会写盘）。`sync_buffers` 改名后对**未修改**的 buffer 执行一次 `:edit!`（`keepalt keepjumps silent`）来清除它，这是有副作用的操作

**最高原则：绝不重读已修改的 buffer。** 数据安全靠“从不碰未保存内容”从构造上保证，而不是靠重读后的恢复逻辑。因此已修改 buffer 只改名并触发 `BufFilePost`，其余一切原封不动：内容、modified、undo 树、mark、jumplist、changelist、extmark、光标、视图和磁盘文件。代价是它仍带 notedited：

- 对已存在的目标 `:w` 报 E13，**调用方需要对它用 `write!`**，并自行保证“磁盘上仍是编辑前的内容”之类的前提（例如文件刚被移动过来，目标就是原内容），因为 `write!` 会跳过一切覆盖检查
- “文件被外部改动”的保护**不受影响**：已修改 buffer 不重读，buffer 对磁盘文件的 mtime 基线没有被动过，因此不会因为 `sync_buffers` 而重置这项保护。未修改 buffer 重读后则以新的磁盘内容与 mtime 为基线，这是预期

### 重读的跳过条件

满足任一即只改名、不重读（notedited 保留）：

- buffer 已修改（含用户手动 `:set modified` 的 buffer）
- `buftype` 非空
- 新路径不是可读的普通文件：不存在、是目录、无读权限，或是 FIFO / socket / 设备。判断用 `fs_stat` 的 `type == 'file'`（跟随软链接）加 `fs_access(R)`，**不能用 `filereadable`**：它对命名管道也返回 1，而 `:edit!` 读 FIFO 会让 nvim 永久阻塞

跳过的 buffer 之后 `:w` 的结果取决于目标，实测：FIFO 报 E13；不可读文件被 E505、目录被 E17、`nofile` 被 E382 先拦下；目标不存在时 `:w` 直接创建文件，没有问题

### 重读的副作用

- **autocmd 会重新触发**：BufReadPre/Post、FileType 等都会再跑一遍。这是有意的——`:edit!` 会让 LSP 与 treesitter detach，只有这些事件才能让它们重新附着；实测加 `noautocmd` 后 treesitter 高亮丢失、用户 autocmd 不触发。LSP 服务端会收到 `didClose` → `didOpen`
- **LSP 重新附着**：FileType 驱动的 client（`vim.lsp.enable`）由重读触发的 FileType 自动重新附着，`sync_buffers` 不插手，不会重复附着。`vim.lsp.start` 手动附着的 client 不会因 FileType 重附，所以重读前会记录 buffer 已附着的 client，重读后对**仍在运行但没有重新附着**的 client 调用 `vim.lsp.buf_attach_client`（已停止的 client 不会被拉起）。其余情形（例如某些进程内 LSP 的 manager 自认为 buffer 已附着、不再重附）无法由 `sync_buffers` 判断，以实际表现为准，这是限制
- **窗口状态**：buffer 在窗口内的折叠会丢失；光标与滚动位置用 `winsaveview` / `winrestview` 恢复，mark 基本不受影响（`:edit!` 不调整 mark），唯一例外是 `'"` mark，重读后会被设为当前光标位置
- **窗口绑定**：`rundo`、`winrestview` 显式绑定重读开始时的窗口与 buffer，重读期间 autocmd 切走窗口或标签页也不会作用到别的窗口或 buffer；原窗口已关闭或不再显示该 buffer 时只恢复 undo，不恢复视图
- **编码与换行**：重读显式带 `++enc=<fileencoding> ++ff=<fileformat>`，不会把 `++enc=cp936` 打开的文件重新探测成 latin1，也不会把 `++ff=unix` 打开的 CRLF 文件改回 dos；binary 由 `:edit!` 自己保留
- **readonly**：重读按文件权限重置它，用户手动 `:set ro` 的状态在重读后恢复
- **undo 链**：已保存的 buffer 有 undo 历史很常见。`:edit!` 在行数 ≥ `undoreload`（默认 10000）时会清空 undo 历史，小 buffer 则会多出一个按了没反应的 undo 步。所以有历史（`undotree().seq_last > 0`）的 buffer 重读前用 `wundo!` 存到临时文件，重读后 `rundo` 恢复，临时文件用完即删。没有历史的 buffer 不做这件事，仍会多出那个 undo 步（实测，`:edit!` 自身行为）。磁盘内容与 buffer 不一致（如文件被外部改过）时 `rundo` 会因内容校验失败，退化为 `:edit!` 的默认行为

### 重读期间 autocmd 报错

BufReadPre/BufReadPost/FileType 里的用户 autocmd 报错时，`:edit!` 的 `vim.cmd` 会抛错，但磁盘内容往往已经读进来了，所以**不依赖 `:edit!` 的返回值**，只看是否出错。出错时：

- 内容被破坏（例如 BufReadPre 报错会把 buffer 清空成一个空行并误置 readonly）则恢复原行、`fileformat` / `fileencoding` / `endofline` / `fixendofline` / `bomb`、readonly，并把 modified 置回 false
- 用 WARN 通知把原始错误信息告诉用户，并说明 buffer 已恢复；恢复不了（例如 autocmd 把 buffer 置为 nomodifiable 且磁盘内容与重读前不同）时如实写“未能完整恢复，请检查”
- **notedited 不会被清除**：实测 `:w` 仍报 E13，需要 `:w!`

### 其它

- buffer 在 `BufFilePost` 等 autocmd 里被 wipe 时，`sync_buffers` 不抛错，也不会中断同一次目录改名里其余 buffer 的处理：入口与每次使用 bufnr 前都校验 `nvim_buf_is_valid`
- 未命中的 buffer 不受影响

## 目录统计边界

`dir_scan.shallow()` 是同步的，但只读直接子项，成本与目录宽度成正比，可以直接在光标移动这类高频路径上调用

`dir_scan.scan()` 是递归的，成本与目录下的 inode 总数成正比，**必须当成长任务对待**。它用显式 DFS 栈保存 scandir 句柄，每处理一个 entry 检查一次预算（默认 `2000` entries 或 `8ms`），超预算就让出到下一个事件循环，因此单片占用可控而不是一次跑完：

```lua
local DirScan = require('vv-utils.fs.dir_scan')
local handle = DirScan.scan(path, {
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
- 达到 `max_entries` 时以 `truncated = true` 结束，`on_done` 仍会触发。调用方必须把它渲染成「至少这么多」而不是最终值——`dir_render.lines()` 已经这样处理

`dir_render.lines()` 对未完成和已截断的扫描会拼上 `file_info_highlight.markers` 里的状态标记，`file_info_highlight.apply()` 据此把中间值高亮成独立分组，避免被误读成结果

## 事务边界

`new_transaction()` 的实例会记录文件快照，在真正写入前重验快照，失败后执行补偿回滚，并保留一层成功事务的撤回能力

它把通用的事务状态机交给 [`vv-utils.transaction`](../transaction/README.md)，自身只提供文件读取、写入、快照和未保存 buffer 检查策略。它适合 WorkspaceEdit 或批量重命名等需要原子语义的流程
