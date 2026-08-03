# `vv-utils.color`

## 职责

在高亮、主题和图形计算之间统一颜色输入。所有入口都会把输入转为独立的 `{ r, g, b, a }`，从而避免调用方直接修改共享表

## 使用

```lua
local color = require('vv-utils.color')

local overlay = color.parse('#0f08')
local hex = color.to_hex(overlay) -- '#00ff0088'
local rgb = color.to_integer('#00ff00') -- 0x00ff00
local mixed = color.mix('#ff0000', '#0000ff', 0.5)
local opaque = color.composite('#ff000080', '#0000ff')
```

## 输入与 API

颜色输入可以是 `0xRRGGBB` 整数、`#RGB`、`#RGBA`、`#RRGGBB`、`#RRGGBBAA`，或 `{ r, g, b, a? }`。通道必须是 0–255 的整数

| 函数 | 说明 |
|---|---|
| `parse(value)` | 归一化为 RGBA，省略 `a` 时为 255 |
| `to_hex(value, opts?)` | 输出小写 Hex；`alpha` 可为 `'auto'`、`'always'`、`'never'` |
| `to_integer(value, opts?)` | 输出 Neovim 使用的 `0xRRGGBB` 整数 |
| `mix(first, second, amount)` | 按 `0..1` 比例插值全部四个通道 |
| `composite(foreground, background)` | 执行标准 source-over alpha 合成 |

## 边界

`to_integer()` 不能无损表达透明度：透明色必须提供 `opts.background` 先合成，或显式传 `discard_alpha = true`。这不是解析失败，而是调用方必须选择的渲染策略
