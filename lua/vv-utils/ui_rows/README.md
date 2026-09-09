# `vv-utils.ui_rows`

Shared rendering primitives for text/chunks rows. `tree_panel` and `modal` use this contract so semantic highlights and virtual text are rendered consistently.

```lua
local rows = require('vv-utils.ui_rows')
rows.set_line(buf, namespace, 0, {
  chunks = {
    { 'Name: ', 'Comment' },
    { 'value', 'String' },
  },
})
```

`statusline(row)` converts the same row shape to a highlight-aware statusline string. `normalize(row)` accepts either a row table or a plain string.

`expand(row)` splits newlines in text/chunks and virtual text into physical rows while preserving chunk highlights. `render(row)` converts those rows into `{ text, highlights, virt_text, virt_text_pos }` values for callers that need to compose prefixes or other layout policy before writing a buffer. A row containing only `virt_text` expands to an empty physical line with its virtual mark.
