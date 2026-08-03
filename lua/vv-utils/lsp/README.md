# `vv-utils.lsp`

## 职责

提供与业务无关的 LSP 编辑原语。入口是 facade：`require('vv-utils.lsp').workspace_edit`、`.code_actions`、`.fix`、`.file_operations`；实际策略（何时触发、是否通知、如何选文件）由调用方负责

## WorkspaceEdit

`workspace_edit.prepare(edits, opts?)` 规范化并构造事务；`validate(transaction)` 检查冲突与快照；`apply(transaction, opts?)` 原子应用；`restore(transaction)` 回滚；`cleanup(transaction)` 释放临时状态。它支持多客户端结果合并、去重与冲突检查

## Code Action 与修复

`code_actions.collect_document_fixes(opts)` 收集可安全应用的文档修复事务；`fix_document(opts)` 直接应用文档或行范围修复。`fix.file(opts)` 与 `fix.files(paths, opts?)` 等待多 LSP 客户端修复收敛后再原子写入；辅助函数 `detect_filetype`、`check_path_support`、`wait_for_clients` 可用于调用方预检

## 文件重命名协议

`file_operations.will_rename_sync` / `will_rename_async` 收集 `workspace/willRenameFiles` 的编辑，`notify_did_rename` 发送 `workspace/didRenameFiles`，`clients(capability)` 查询支持该能力的客户端

## 边界

该模块**不移动文件**，也不替调用方选择交互或错误呈现。文件移动、事务编排及生命周期 owner 必须在上层；异步回调仍应由调用方的 request scope 或等价机制防止过期回写
