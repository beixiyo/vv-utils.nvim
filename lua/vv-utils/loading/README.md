# `vv-utils.loading`

通用 loading 帧动画。所有形态共享按 `interval_ms` 分组的一个时钟（帧同步，无订阅者时释放 timer），返回的 handle 支持 `set_label(label)`、`redraw()`、`is_active()`、`on_stop(fn)`、`stop()`（幂等）

| 形态 | 画在哪里 | 自动停止 |
|---|---|---|
| `mark(opts)` | buffer 内 `(row, col)` 的 virt_text | buffer wipe |
| `win_text(opts)` | 浮窗 title / footer，stop 时原样恢复 | 窗口关闭 |
| `ticker(opts)` | 不渲染，每帧调 `on_frame(frame, label)` | 无，由调用方停止；`on_frame` 返回 false 时自行停止（含首帧） |
| `slot(create)` | 同一位置多个并发请求共用一个 handle，引用计数 | `slot:dispose()` |
| `blocking(opts, fn, ...)` | 同步阻塞前画静态帧 / echo 并 redraw，执行完清理 | fn 返回或抛错 |

## 着色

帧与 label 分段上色，均以 `default` 注册，colorscheme 或用户 `nvim_set_hl` 可直接覆盖：

| 高亮组 | 作用 | 默认 |
|---|---|---|
| `VVLoading` | 帧（含 prefix / suffix / `width` 补齐空格） | 蓝色 `#7aa2f7` |
| `VVLoadingLabel` | label；`blocking` 的 echo 文案 | link `Comment` |

单个调用可用 `mark` 的 `hl` / `label_hl` 覆盖；`win_text` 默认 format 按同样规则输出 chunk 列表，自定义 `format` 返回 chunk 列表即可任意上色

## 落点选择

- 名字后面：`pos = 'inline'`，`col` 取名字结束的字节列
- 名字前固定宽度的槽位（图标、折叠箭头）：`pos = 'overlay'` + `width = 槽位宽度`，不挤动文字
- 文字开头插入：`pos = 'inline'` + `prefix = ''` + `suffix = ' '`
- 短且固定的行（空状态、短 header）：`pos = 'eol'`；长行的 eol 会被窗口截掉，避免使用
- 没有可锚定的行：`win_text` 放 title / footer

## 使用

```lua
local Loading = require('vv-utils.loading')

-- 分支名后显示，150ms 内完成则不显示
local handle = Loading.mark({
  buf = buf,
  get_pos = function()
    local row = find_row(id)
    return row and { row = row, col = name_end_col(row) }
  end,
  label = 'deleting',
  delay_ms = 150,
})
handle:stop()

-- latest-wins 请求：旧请求终结时 release 不会停掉新请求的显示
local slot = Loading.slot(function()
  return Loading.mark({ buf = buf, get_pos = function() return { row = 1 } end, pos = 'overlay', width = 2 })
end)
local release = slot:acquire()
request:set_disposer(release)

-- 浮窗 footer
local footer = Loading.win_text({ win = win, slot = 'footer', label = 'Committing…' })

-- 同步阻塞
Loading.blocking({ echo = 'Fixing all…' }, fix_document, bufnr)
```

## 边界

- `get_pos()` 每帧调用，返回 nil 即隐藏；`col` 超出行长时 clamp 到行尾
- `mark` 每帧清空自己的 namespace 后重画；buffer 内容变化后立即重画一次，宿主 `set_lines` 整块重写不会残留或错位
- `handle:redraw()` 按当前帧立即重画，供宿主在非文本变化（如只改了 `get_pos` 依赖的状态）后调用
- `set_label()` / `redraw()` 在 fast event 中只更新状态，并合并排队到主循环重画；停止后不再交付旧重画。`slot` 的 `release()` 可安全用作 fast-event disposer，有其他在途请求时只恢复其文案，不会误停共享显示
- `interval_ms` 必须为 >= 1 的整数（默认 80），传 0、负数或小数（如 0.5，会被 luv 截断为 0）直接抛错
- `frames` 必须为非空字符串列表（默认 `presets.braille`），否则直接抛错
- `validate_frame_opts(opts, prefix?)` 是上面两条的公共校验（字段为 nil 视为默认值，`opts` 本身为 nil 视为全部取默认，非表（含 `false`）抛错；`prefix` 默认 `'vv-utils.loading: '`）：宿主若推迟到之后才创建 loading（如 prompt 的 spinner），应在自身入口先调用它，避免半初始化后才报错
- `buf = 0` / `win = 0` 在入口归一化为调用时的当前 buffer / 窗口编号，之后切换不影响
- `delay_ms` 期间 `stop()` 无任何副作用；`blocking` 忽略 `delay_ms`
- `handle:on_stop(fn)` 注册的回调与 `clear`（擦除已画内容）抛错时以 ERROR 级 `vim.notify` 报告（`vv-utils.loading: on_stop failed: …` / `clear failed: …`，与渲染失败一致），不影响其余回调与资源释放；handle 停止后再调 `on_stop(fn)`：清理已完成时，主循环中受保护地立即执行，fast event 中延后到主循环执行；停止后清理尚未执行（fast event 中 stop、主循环未轮到）时排进同一批，在 clear 之后执行。以上情况出错均以 ERROR 报告，不抛给调用方
- `stop()` 可在 fast event（如 `vim.uv` timer 回调）中调用：同步置为停止并释放延迟 timer 与时钟订阅，擦除内容与 `on_stop` 回调经 `vim.schedule` 延后到主循环执行；主循环中调用则全部同步完成（包括 fast event 中已 stop、延后清理尚未执行时，主循环再调 `stop()` 会就地完成清理）。多次 `stop()` 只清理一次
- `mark` 的 buffer 内容监听（`nvim_buf_attach`）在 stop 后要等该 buffer 下一次变化或被 wipe 才解除，期间闭包驻留（开销极小）
- `win_text` 对无边框或非浮窗的 `set_config` 失败静默忽略
- `win_text` 每帧写入前检查槽位：宿主在 loading 期间改过值则以宿主新值作为原值，loading 继续显示，stop 时恢复宿主新值
- 同一窗口同一槽位不要叠加多个 `win_text`：后一个会把前一个的帧当成原值，stop 后可能残留一帧 spinner；并发请求必须通过 `slot()` 合并成一个显示
- `blocking` 的 echo 不主动清除，由 fn 之后的结果消息覆盖；fn 抛错时清理后原样重抛原始错误对象
- 同步阻塞期间帧不会推进：需要动画的长任务必须异步化或分片 yield
- `ticker` 不拥有 UI 资源，关闭窗口或销毁 owner 时必须调用 `stop()`
