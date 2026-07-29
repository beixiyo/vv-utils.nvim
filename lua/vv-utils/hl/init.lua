-- Highlight 公共入口：稳定导出注册生命周期与纯颜色计算工具

local registry = require('vv-utils.hl.registry')

return {
  register = registry.register,
  register_dimmed = registry.register_dimmed,
  get_fg = registry.get_fg,
}
