# `vv-utils.scroll`

## 职责

在不改变当前焦点窗口的前提下，为目标窗口提供逐行平滑滚动，并区分手动键盘滚动、自动大跳转和鼠标策略

## 启用

```lua
require('vv-utils').setup({
  scroll = {
    duration = 180,
    key_duration = 120,
    auto_duration = 108,
    auto_max_steps = 10,
    mouse = 'native',
  },
})
```

`setup(opts?)` 安装全局监听与映射，`disable()` 移除输入拦截并取消动画，`get_config()` 返回当前配置

## 调用 API

`window(win_id, lines)` 对指定窗口执行动画滚动；`mouse(direction, win_id?)` 处理滚轮；`with_view_animation(win_id, fn)` 包装显式视口跳转；`with_auto_suppressed(win_id, fn)` 在临界区禁用自动跳转动画，避免手动改变视图后回弹

`mouse = 'native'` 是默认值，不接管滚轮；只有 `'smooth'` 才映射鼠标。`auto_min_lines` 排除小距离滚动，`auto_max_steps` 和 `auto_duration` 限制大跳转的 timer 数量与时长

## 边界

该模块动画的是 window view，不替调用方决定何时打开窗口或改变 buffer。scrollbind 窗口会保留原生同步行为
