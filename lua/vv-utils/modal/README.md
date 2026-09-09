# `vv-utils.modal`

Reusable action-oriented floating window. The caller owns the content and policy; the module owns rendering, buffer-local mappings, and close lifecycle.

```lua
local handle = require('vv-utils.modal').open({
  title = 'Paste Conflict',
  body = {
    { chunks = { { 'Source ', 'Comment' }, { 'project', 'Directory' } } },
    { text = 'The destination already exists.', hl = 'DiagnosticWarn' },
  },
  actions = {
    { id = 'overwrite', label = 'Overwrite', keys = '<C-y>', hl = 'DiagnosticError' },
    { id = 'increment', label = 'Keep Both', keys = '<C-n>', hl = 'DiagnosticOk' },
  },
  cancel = { label = 'Cancel', keys = { 'q', '<Esc>' } },
  on_select = function(id) print(id) end,
  on_cancel = function() end,
})
```

`body` is an ordered list of strings or rows. A row may use `text`/`hl`, `chunks`, `icon`/`icon_hl`, and `virt_text`. Newlines in text/chunks are expanded into physical buffer lines while preserving each chunk's highlight. A row containing only `virt_text` is also valid. Use `render(ctx)` instead of `body` when rows depend on caller context.

Actions are ordered and require a unique `id`, `label`, and non-empty `keys` list. Key encodings are normalized and conflicts between actions or cancel are rejected before a window is opened. The first action key is shown in the footer by default using `vv-utils.keys.display` (`<C-y>` is displayed as `^y`); set `hint = false` to hide an action from the footer while retaining its mappings.

`on_select` and `on_cancel` run after the window closes. Callback errors are isolated and reported with `vim.notify`. `close()` is idempotent, never invokes a callback, and `is_open()` reports the current window state.

`window` accepts `border`, `title_pos`, `min_width`, `max_width`, `margin`, `zindex`, and `chrome` options. The default filetype is `vv-modal`.
