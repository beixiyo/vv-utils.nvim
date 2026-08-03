# `vv-utils.mouse`

## 职责

保护 nofile 面板免受鼠标选择副作用影响，特别是从其他窗口按住拖进面板时意外进入 Visual 模式的场景

## API 与边界

`block_visual_drag(buf)` 为指定 buffer 安装 ModeChanged 防护与 buffer-local 拦截。它只应在临时 UI buffer 调用；普通文件 buffer 的鼠标选择语义不会被改动，也不应通过这个模块全局禁用 Visual 模式

## 使用

在创建 nofile buffer 并设置其交互前调用一次即可。面板销毁时 buffer 生命周期会一并结束，无需把该保护扩展到其他窗口
