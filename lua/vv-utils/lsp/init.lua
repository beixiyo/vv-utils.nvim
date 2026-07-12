---LSP 通用原语 facade
local M = {}

return setmetatable(M, {
  __index = function(_, key)
    local module = require('vv-utils.lsp.' .. key)
    rawset(M, key, module)
    return module
  end,
})
