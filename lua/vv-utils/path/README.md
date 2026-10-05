# `vv-utils.path`

## 职责

提供不依赖插件状态的路径规范化、展示缩略和项目根定位。项目根定位优先尊重 Git；仅在不在 Git 仓库时才按语言生态的清单文件回退

## 使用

```lua
local path = require('vv-utils.path')

local root = path.find_root('/work/repository/apps/web/src/App.tsx')
local label = path.collapse_middle('frontend/electron/renderer/App.tsx', {
  head = 1,
  tail = 2,
})
-- 面板只剩 24 列时逐级压缩：tail 3 → 2 → 1，再 head 1 → 0（`…/文件名`）
local fitted = path.collapse_middle('packages/web/src/routes/admin/index.tsx', { max_width = 24 })
```

## API

| 函数 | 说明 |
|---|---|
| `norm(path)` | 将分隔符与冗余路径成分规范化，返回可比较的路径 |
| `collapse_middle(path, opts?)` | 仅为显示折叠中间目录；`head` 默认保留 1 层、`tail` 默认保留 3 层、`ellipsis` 默认 `…`；`max_width`（默认 nil 不限宽）按显示宽度逐级退化：`tail` 逐级减到 1，最后 `head` 降为 0，全部超宽返回最短一级 |
| `find_root(path, opts?)` | 从路径向上寻找根目录；优先 Git，未命中时按 `opts.markers` 查找 manifest |
| `get_root(buf?)` | 对 buffer 的文件路径执行根定位；默认当前 buffer |
| `get_cwd()` | 返回当前 Neovim 工作目录 |

## 边界

`collapse_middle()` 不修改真实路径，也不保证结果可重新用于文件访问；`max_width` 不截断文件名，调用方需自行处理文件名本身超宽的情况。`find_root()` 的 manifest 回退仅用于没有 Git 信息的场景，不能替代调用方对 monorepo 子包边界的业务判断
