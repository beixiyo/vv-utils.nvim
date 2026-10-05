-- 鼠标交互工具：保护 nofile UI 面板（vv-explorer / vv-git 等）不被鼠标拖拽 / 多击误入 visual
--
-- 为什么单有 <LeftDrag> / <2-/3-/4-LeftMouse> -> <Nop> 不够：
--   各面板把这些键映射成 <Nop> 来挡拖拽（VISUAL）/ 双击选词 / 三击选行 / 四击选块，但
--   buffer-local 鼠标映射只在「该 buffer 的窗口已是当前窗口」时才被查。当用户从别的窗口
--   （编辑区）点进面板再拖拽 / 多击时，首个按下事件在「源窗口仍是当前窗口」的瞬间被解析，
--   走的是源窗口的 keymap（没有 nop）→ arm 选区 → 进 VISUAL，焦点此刻才切到面板，
--   buffer-local 映射已无从拦截。'mousemodel' = 'extend' 会让这条路径更容易触发
--   （已用真实 nvim ModeChanged 日志确证：面板上 <2-LeftMouse> 确为 <Nop> 仍进了 v。）
--
-- 兜底：给面板 buffer 挂 buffer-scoped ModeChanged 守卫，一旦该 buffer 内进入
-- visual / select（面板里这只可能由鼠标拖拽 / 多击产生——键盘 v/V/<C-v> 已被各面板 Nop）就
-- 退回 normal
--
-- 退出方式必须是 vim.schedule + nvim_input(<C-\><C-N>)：
--   ① 同步 feedkeys 只排进 typeahead 不立即执行，选区会挂到用户下次按键（真实日志实测）；
--      故须 vim.schedule 延到事件循环安全点再注入
--   ② 用 <C-\><C-N> 而非 <Esc>：<Esc> 经 nvim_input 会被当转义序列前缀等待、且可能命中面板的
--      <Esc> 映射（vv-git 把 <Esc> 绑成关面板/清选区），在 vv-git 里退不干净（实测）；
--      <C-\><C-N> 无歧义、不吃映射，强制回普通模式

local M = {}

-- 退出 visual 用 <C-\><C-N> 而非 <Esc>：<C-\><C-N> 是「强制回普通模式」的规范写法，无歧义、
-- 不吃任何 buffer-local 映射。单个 <Esc> 经 nvim_input 会被当转义序列前缀、且可能命中面板上
-- 的 <Esc> 映射（如 vv-git 把 <Esc> 绑成关面板/清选区），导致退不干净（实测 vv-git 踩过）
local CTRL_N = vim.api.nvim_replace_termcodes('<C-\\><C-N>', true, false, true)

-- visual / select 系模式首字符：v / V / <C-v> / s / S / <C-s>
local VISUAL_MODES = {
  v = true, V = true, ['\22'] = true,
  s = true, S = true, ['\19'] = true,
}

---给 nofile UI 面板 buffer 加「禁止鼠标拖拽 / 多击进入 visual」守卫
---
---autocmd 随 buffer wipe 自动清理；每次重建面板各自挂一份即可
---@param buf integer  面板 buffer
function M.block_visual_drag(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end

  vim.api.nvim_create_autocmd('ModeChanged', {
    buffer = buf,
    desc = 'vv-utils: 面板禁止鼠标拖拽 / 多击进入 visual',
    callback = function()
      if not VISUAL_MODES[vim.fn.mode()] then return end
      -- 延到安全点 + 低层注入 <C-\><C-N>，强制立刻退出（同步 feedkeys 不生效，见文件头注释）
      vim.schedule(function()
        if VISUAL_MODES[vim.fn.mode()] then
          vim.api.nvim_input(CTRL_N)
        end
      end)
    end,
  })
end

---buffer-local 鼠标映射的入口守卫：鼠标事件不在面板窗口内时，把它交还给鼠标所在的窗口
---
---Neovim 按「按键时的当前 buffer」查鼠标映射：焦点在面板时右键点编辑区，会先进面板的
---buffer-local 映射，回调里的 getmousepos 指向的却是编辑区的行。守卫返回 true 时调用方必须直接 return：
---  · 鼠标在其他窗口：切过去并以可重映射方式重发同一个键，由该窗口自己的映射或内置行为处理
---  · 鼠标不在任何窗口（命令行、分隔线等）或目标窗口不可聚焦：吞掉事件，不执行面板动作
---返回 false 表示事件确实落在 win 内，调用方继续原逻辑
---@param win integer 面板窗口
---@param key string 映射的鼠标键，如 '<RightMouse>'
---@return boolean handled
function M.redispatch_outside(win, key)
  local target = vim.fn.getmousepos().winid
  if target == win then return false end
  -- 目标已是当前窗口说明是重发后又回到了这里（同一面板 buffer 显示在多个窗口）：吞掉，避免无限重发
  if target == 0 or target == vim.api.nvim_get_current_win() then return true end
  if not pcall(vim.api.nvim_set_current_win, target) then return true end
  -- 'm' 可重映射：命中目标 buffer 的 buffer-local 映射或全局映射
  vim.api.nvim_feedkeys(vim.keycode(key), 'mi', false)
  return true
end

return M
