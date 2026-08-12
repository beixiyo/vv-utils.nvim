# `vv-utils.keys`

把 Neovim 的键位记号统一显示为紧凑提示文本，不注册映射，也不依赖图标字体或 `vv-icons`

```lua
local Keys = require('vv-utils.keys')

Keys.display('<C-y>')  -- ^y
Keys.display('<M-p>')  -- ⌥p
Keys.display('<S-Tab>') -- ⇧Tab
Keys.display('<D-v>')  -- ⌘v
Keys.display('<CR>')   -- ↵
Keys.display('<NL>')   -- ^j
Keys.display('<C-W>q') -- ^wq
Keys.hint('Confirm', '<C-y>') -- Confirm ^y
```
