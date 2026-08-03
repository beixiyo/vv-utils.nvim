# `vv-utils.blink`

## 职责

把当前 buffer 的 `vv-utils.completion` descriptor 适配为 Blink source。没有 descriptor 的 buffer 自动禁用，因此可以作为共享 source 注册一次

```lua
providers = {
  vv_completion = {
    module = 'vv-utils.blink',
    opts = { max_items = 50, scan_max_items = 1000, timeout_ms = 250 },
  },
}
```

`new(opts?)` 创建 source。`max_items` 限制最终候选，`scan_max_items` 限制递归扫描量，`timeout_ms` 限制扫描等待。adapter 会保留 descriptor 声明的 `pre_filtered` 顺序，并在异步 descriptor 被取消后拒绝过期回写

Blink 是可选集成；候选规则和资源取消仍属于 completion descriptor 的提供方
