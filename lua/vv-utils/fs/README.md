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
| 文件识别 | `inspect_file(path, opts?)`、`is_binary(path, opts?)`、`file_info_lines(info, opts?)`、`highlight_file_info(buf)` |
| 事务 | `new_transaction(opts)` |

`inspect_file()` / `is_binary()` 基于内容判断，适合在展示或批量处理前跳过二进制文件；不是按扩展名猜测

## 事务边界

`new_transaction()` 的实例会记录文件快照，在真正写入前重验快照，失败后执行补偿回滚，并保留一层成功事务的撤回能力。它适合 WorkspaceEdit 或批量重命名等需要原子语义的流程；普通单文件读写不应为了形式统一而套事务
