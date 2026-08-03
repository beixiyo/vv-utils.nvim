# `vv-utils.sys`

`open_default(path)` 通过 `vim.ui.open` 交给系统默认应用打开路径，并在 niri 环境处理打开后焦点恢复

## 使用

```lua
require('vv-utils.sys').open_default(vim.api.nvim_buf_get_name(0))
```

函数返回的是异步打开流程的结果/控制语义，调用方仍应负责错误呈现和 owner 生命周期；该模块不替插件保存窗口、决定目标应用或改写系统关联
