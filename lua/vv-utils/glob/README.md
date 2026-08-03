# `vv-utils.glob`

## 职责

把输入框中的 VS Code 风格 glob 转换为框架无关的 pattern，或转换为 ripgrep 参数。它处理顶层逗号、`!` 排除、`./` 根锚定、brace 与字符类，避免调用方各自实现一套不一致的拆分规则

## 使用

```lua
local glob = require('vv-utils.glob')

local rules = glob.compile_list('*.{ts,tsx}, ./packages/core/src/, !vendor')
local rg_args = glob.compile_rg_list('*.lua, !tests/**')
```

## API

| 函数 | 返回与用途 |
|---|---|
| `split(raw)` | 按**顶层**逗号拆分原始输入，不误拆 brace、字符类或转义逗号 |
| `compile(source, opts?)` | 编译一条规则，返回 `{ patterns, negated }` |
| `compile_list(raw, opts?)` | 拆分并按顺序编译多条规则 |
| `compile_rg(source, opts?)` | 将一条规则转换为 ripgrep `--glob` 参数 |
| `compile_rg_list(raw, opts?)` | 批量转换为 ripgrep 参数 |

`opts.negate = true` 强制生成排除规则。输出以 `/` 开头时锚定搜索根；普通路径会同时匹配任意深度中的本体与后代

## 边界

模块只负责语法与 pattern 语义，不遍历文件系统、不调用 ripgrep，也不决定哪些 glob 应交给某个 UI 或搜索后端
