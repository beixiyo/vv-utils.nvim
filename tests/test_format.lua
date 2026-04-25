-- vv-utils.format 测试
-- 用例对齐 vsc-word-space 的 add-spaces.test.ts
-- 运行：cd vv-utils.nvim && nvim --headless -u NONE -l tests/test_format.lua

local this = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
local plugin_root = vim.fn.fnamemodify(this, ':h:h')
package.path = plugin_root .. '/lua/?.lua;' .. plugin_root .. '/lua/?/init.lua;' .. package.path

local F = require('vv-utils.format')

local passed, failed = 0, 0
local function eq(name, got, want)
  if got == want then
    passed = passed + 1
    print('[PASS] ' .. name)
  else
    failed = failed + 1
    print('[FAIL] ' .. name)
    print('       got:  ' .. vim.inspect(got))
    print('       want: ' .. vim.inspect(want))
  end
end

-- ── add_spaces_around_english ────────────────────────────────────────────────
local A = F.add_spaces_around_english

eq('basic 我喜欢apple', A('我喜欢apple'), '我喜欢 apple')
eq('basic apple很好吃', A('apple很好吃'), 'apple 很好吃')
eq('basic 这是一个test', A('这是一个test'), '这是一个 test')
eq('basic hello世界', A('hello世界'), 'hello 世界')

eq('num 完成率100', A('完成率100'), '完成率 100')
eq('num 100完成', A('100完成'), '100 完成')
eq('num 这是2026年', A('这是2026年'), '这是 2026 年')

eq('prefix @frps', A('你的用户名@frps的公网'), '你的用户名 @frps 的公网')
eq('prefix #tag', A('搜索#tag标签'), '搜索 #tag 标签')
eq('prefix $100', A('金额$100美元'), '金额 $100 美元')

eq('suffix 100%', A('完成100%成功'), '完成 100% 成功')
eq('suffix 30°', A('温度是30°今天'), '温度是 30° 今天')
eq('suffix C++', A('C++教程'), 'C++ 教程')

eq('md **bold**', A('测试**bold**测试'), '测试 **bold** 测试')
eq('md _italic_', A('测试_italic_测试'), '测试 _italic_ 测试')
eq('md `code`', A('测试`code`测试'), '测试 `code` 测试')
eq('md link', A('参考[Google](https://google.com)搜索'), '参考 [Google](https://google.com) 搜索')

eq('mixed arch+@frps+IP', A('你的arch用户名@frps的公网IP或域名'), '你的 arch 用户名 @frps 的公网 IP 或域名')
eq('mixed _lodash_ _map_', A('使用_lodash_库的_map_方法'), '使用 _lodash_ 库的 _map_ 方法')

-- ── clean_line_trailing ──────────────────────────────────────────────────────
local C = F.clean_line_trailing

eq('clean 单句号', C('这是一句话。'), '这是一句话')
eq('clean 多句号', C('结束。。。'), '结束')
eq('clean 句号+空格', C('完成。   '), '完成')
eq('clean 句号+tab', C('好的！\t'), '好的')
eq('clean 问号', C('对吗？'), '对吗')
eq('clean 纯空格', C('hello   '), 'hello')
eq('clean 纯tab', C('hello\t\t'), 'hello')
eq('clean 中间不动', C('A。B。'), 'A。B')
eq('clean 多行', C('行一。\n行二！  \n  无尾  '), '行一\n行二\n  无尾')
eq('clean 无变化', C('普通文本'), '普通文本')

print(('\n%d 通过, %d 失败'):format(passed, failed))
if failed > 0 then os.exit(1) end
