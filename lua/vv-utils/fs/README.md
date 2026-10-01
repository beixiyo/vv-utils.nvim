# `vv-utils.fs`

文件、路径、buffer 同步和多文件事务的底层原语。简单操作直接执行；需要快照校验和补偿回滚的编辑流程走事务 API

## API

| 分类 | 函数 |
|---|---|
| 路径 | `exists(path)`、`is_directory(path)`、`is_dir_empty(path)`、`realpath(path)`、`unique_dest(destination)` |
| 文件操作 | `mkdir_p(directory)`、`create_file(file)`、`delete(target)`、`rename(source, destination)`、`copy(source, destination)` |
| 内容 | `read_all(file)`、`write_all(file, content, opts?)`、`load_json(source, opts?)`、`save_json(file, data, opts?)` |
| 临时文件 | `temp.write(content, opts?)`、`temp.create(opts?)`、`temp.cleanup(paths)` |
| buffer | `sync_buffers(old, new)`：文件移动后让已打开的 buffer 跟上，见 [sync_buffers](#sync_buffers) |
| buffer | `close_stale_buffers(path)`：关闭指向已删除文件的 buffer，见 [close_stale_buffers](#close_stale_buffers) |
| 事务 | `new_transaction(opts)`，见 [事务](#事务) |

文件与目录信息在独立模块：

| 模块 | 函数 |
|---|---|
| `fs.file_probe` | `inspect(path, opts?)`、`is_binary(path, opts?)`，按内容判断，不看扩展名 |
| `fs.file_render` | `lines(info, opts?)`、`format_size(bytes)` |
| `fs.dir_scan` | `shallow(path)`、`scan(path, opts?)`，见 [目录统计](#目录统计) |
| `fs.dir_render` | `lines(info, opts?)` |
| `fs.file_info_highlight` | `apply(buf)` |

细节：

- `write_all()`：`mode` 控制新文件权限，`directory_mode` 控制新建父目录权限，已有文件和目录保持原权限
- `temp.write()` / `temp.create()`：独占创建，默认 `0600`；调用方持有路径，用幂等的 `temp.cleanup()` 清理
- `is_directory()` 跟随软链接；`is_dir_empty()` 只读第一个成员，不是目录或读不了时返回 `nil, err`

## sync_buffers

`sync_buffers(old, new)`：`old` 可以是文件或目录。命中的 buffer 改名并触发 `BufFilePost`

| buffer 状态 | 处理 | 之后 `:w` |
|---|---|---|
| 未修改 | 改名后 `:edit!` 重读，清除 notedited | 正常 |
| **已修改** | **只改名，绝不重读** | 目标已存在时报 E13，调用方用 `write!` |

> **最高原则：绝不重读已修改的 buffer。** 数据安全靠“从不碰未保存内容”保证，而不是靠事后恢复。已修改 buffer 的内容、undo、mark、jumplist、extmark、光标、视图、mtime 基线都原样保留

为什么要重读：`nvim_buf_set_name` 会给 buffer 打上 notedited，对已存在文件 `:w` 报 E13。实测只有 `:edit!` 或 `:write!` 能清掉它，后者会写盘。对已修改 buffer 用 `write!` 时，调用方要自己保证磁盘仍是编辑前的内容，因为 `write!` 跳过一切覆盖检查

### LSP 同步

Neovim 内置 LSP **不处理 buffer 改名**：改名后服务端收不到任何通知，旧路径会一直被当成“客户端已打开”。内置 LSP 只在下一次触发 `BufWritePost` 的保存时补发通知，`noautocmd write` 则完全不会补发

所以 `sync_buffers` 对命中的 buffer：

1. 改名前 `buf_detach_client` 所有已初始化的 client → 服务端收到**旧 URI** 的 didClose
2. 改名、重读
3. 对仍在运行、还没重新附着的 client `buf_attach_client` → **新 URI** 的 didOpen（带当前内容，含未保存修改）

- `vim.lsp.enable` 的 client 由重读触发的 FileType 自行附着，不会重复
- 已停止的 client 不会被拉起；会触发一次 `LspDetach` / `LspAttach`
- 尚未初始化的 client 不动。`vim.lsp.enable` 管理的会在初始化后用新名字 didOpen；`vim.lsp.start` 手动附着的会在重读后丢失附着（这是原有行为，不是本机制引入）

**Neovim 核心限制（实测）**：内置 LSP 在 buffer 首次附着时记下 URI，只有 buffer 被卸载才会刷新。`:edit!` 会卸载 buffer，所以未修改 buffer 的重读没有问题。已修改 buffer 不重读，所以：

- 之后 `write!` 发出的 willSave 仍用旧 URI
- 写盘后文件若被外部改动并被 checktime 重新加载，服务端会收到旧 URI 的 didClose 加上新 URI 的重复 didOpen

### 不重读的情况

满足任一就只改名、保留 notedited：

- buffer 已修改，包括手动 `:set modified`
- `buftype` 非空
- 新路径不是可读的普通文件，比如不存在、目录、无读权限、FIFO / socket / 设备。判断用 `fs_stat().type == 'file'` 加 `fs_access(R)`。**不能用 `filereadable`**：它对 FIFO 也返回 1，而 `:edit!` 读 FIFO 会永久阻塞

跳过后 `:w` 的实测结果：FIFO 报 E13；不可读文件报 E505，目录报 E17，`nofile` 报 E382；目标不存在时直接创建文件

### 重读的副作用

| 方面 | 行为 |
|---|---|
| autocmd | BufReadPre/Post、FileType 会重跑。这是有意的：LSP 和 treesitter 靠它们重新附着，实测加 `noautocmd` 后高亮会丢 |
| 视图 | 折叠丢失；光标和滚动由 `winsaveview` / `winrestview` 恢复；mark 不变，只有 `'"` 被设为当前光标 |
| 窗口绑定 | `rundo` 和 `winrestview` 绑定重读开始时的窗口；原窗口已关闭或不再显示该 buffer 时，只恢复 undo，不恢复视图 |
| 编码与换行 | 重读带 `++enc` / `++ff`，不会重新探测编码或换行；binary 由 `:edit!` 自己保留 |
| readonly | 重读按文件权限重置，手动 `:set ro` 的会恢复 |
| undo | 有历史的 buffer 先 `wundo!` 到临时文件，重读后 `rundo` 恢复，用完即删。因为 `:edit!` 在行数 ≥ `undoreload` 时清空历史，小文件则多出一个无效步。没有历史的 buffer 仍会多出那一步。磁盘内容与 buffer 不一致时 `rundo` 校验失败，退化为默认行为 |

### autocmd 报错

用户 autocmd 在重读时报错，`:edit!` 会抛错，但磁盘内容往往已经读进来了，所以只看是否出错，不看返回值：

- 内容被破坏时（例如 BufReadPre 报错会清空 buffer 并误置 readonly），恢复原行、`fileformat` / `fileencoding` / `endofline` / `fixendofline` / `bomb`、readonly，并把 modified 置回 false
- 用 WARN 告知原始错误；恢复不了时如实提示“未能完整恢复，请检查”
- notedited 不清除，`:w` 仍报 E13

buffer 在 `BufFilePost` 等 autocmd 里被 wipe 时不抛错，也不打断同一次目录改名里其余 buffer 的处理

## close_stale_buffers

`close_stale_buffers(path)`：关闭 `path`（文件或目录）下指向**磁盘已不存在文件**的 buffer，返回已关闭的 bufnr 列表，不抛错

用于“文件已被删除或移走，buffer 还留着”的场景，例如 Git 丢弃改动删掉了未跟踪文件，或文件操作的目标路径上残留着旧 buffer。这类 buffer 仍挂着 LSP，服务端会把它当成已打开的文档

只关闭同时满足以下条件的 buffer：

- 已加载、`buftype` 为空、**未修改**
- 名字等于 `path` 或位于 `path/` 之下（只做前缀匹配、不解析软链接，传入路径应与 buffer 名同一形式，通常是 realpath）
- `fs_lstat` 查不到（悬空软链接算存在）

行为：

- 用不带 force 的 wipe 关闭，wipe 前再校验一次未修改。卸载时 client detach，服务端收到 didClose
- 显示在窗口里的 buffer 先用 `bufdelete.replace_in_windows` 换掉，窗口保留。不用 `bufdelete.delete`，因为它内部是强制的 `bdelete!`
- `winfixbuf` 窗口换不掉，这个 buffer 保留不关，否则会连窗口一起关掉

> ⚠️ 外部删除文件后，buffer 可能是内容的唯一副本，关闭时 undo 也一起丢失。只在“这个路径马上要被别的文件占用”或“删除是用户确认过的”场景调用

## 目录统计

- `dir_scan.shallow()`：同步，只读直接子项，可以放在光标移动这类高频路径上
- `dir_scan.scan()`：递归，成本与 inode 总数成正比，**当成长任务对待**。按预算分片（默认 `2000` entries 或 `8ms`），超预算就让出事件循环

```lua
local DirScan = require('vv-utils.fs.dir_scan')
local handle = DirScan.scan(path, {
  max_entries = 200000,
  on_progress = function(result) render(result) end, -- result.done == false
  on_done = function(result) render(result) end,
})

handle.cancel() -- 幂等；取消后不再触发回调
```

分片之间用 uv timer 让出，**不能改成 `vim.schedule` 自递归**：schedule 队列会在同一批次里排空，分片退化成忙循环。实测 89 万文件的目录连续占用 5.9s，改成 timer 后单次占用 18ms。[目录统计测试](../../../tests/test_fs_dir_info.lua) 用 uv idle 的迭代计数守住这一点

接入前确认：

- 不跟随软链接，指向祖先目录的链接不会成环
- 不过滤，口径与 `du` 一致
- 达到 `max_entries` 时以 `truncated = true` 结束，`on_done` 照常触发，应渲染成“至少这么多”。`dir_render.lines()` 已经这样处理，并用 `file_info_highlight` 把未完成或已截断的中间值高亮成独立分组

## 事务

`new_transaction()` 记录文件快照，写入前重验，失败时补偿回滚，并保留一层成功事务的撤回。通用状态机由 [`vv-utils.transaction`](../transaction/README.md) 提供，这里只负责文件读写、快照和未保存 buffer 检查。适合 WorkspaceEdit、批量重命名等需要原子语义的流程
