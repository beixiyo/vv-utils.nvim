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

-- ── clean_prose（散文：删行尾句号 + 闭合符遮挡的句号；保留 ？！/缩进/串内空格）──
local C = F.clean_prose

eq('clean 单句号', C('这是一句话。'), '这是一句话')
eq('clean 多句号', C('结束。。。'), '结束')
eq('clean 句号+空格', C('完成。   '), '完成')
eq('clean 句号+tab', C('完成。\t'), '完成')
eq('clean 叹号默认保留', C('好的！'), '好的！')
eq('clean 问号默认保留', C('对吗？'), '对吗？')
eq('clean 纯空格', C('hello   '), 'hello')
eq('clean 纯tab', C('hello\t\t'), 'hello')
eq('clean 中间不动', C('A。B。'), 'A。B')
eq('clean 多行', C('行一。\n行二！  \n  无尾  '), '行一\n行二！\n  无尾')
eq('clean 无变化', C('普通文本'), '普通文本')

-- 句号被行尾闭合符挡住：删句号、保留闭合符
eq('clean 闭合符 **加粗。**', C('**重点。**'), '**重点**')
eq('clean 闭合符 *斜体。*', C('*斜体。*'), '*斜体*')
eq('clean 闭合符 行内代码`。', C('看 `code`。'), '看 `code`')
eq('clean 闭合符 括号内（。）', C('（说明。）'), '（说明）')
eq('clean 闭合符 括号外（）。', C('（说明）。'), '（说明）')
eq('clean 闭合符 引号。"', C('他说。"'), '他说"')
eq('clean 闭合符 中文引号。”', C('他说。”'), '他说”')
eq('clean 闭合符无句号不变', C('**加粗**'), '**加粗**')
eq('clean 闭合符前中间句号保留', C('A。B**'), 'A。B**')
eq('clean 多行含闭合符', C('一。**\n二`x`。\n三'), '一**\n二`x`\n三')

-- ── clean_prose（批量散文：代码围栏内只清注释行句号；围栏外仅删句号，不删 ？！）──
local PR = F.clean_prose
eq('prose 代码块普通文本保留句号', PR('文本。\n```\n代码。\n```\n结尾。'), '文本\n```\n代码。\n```\n结尾')
eq('prose yaml 代码块注释删句号', PR('```yaml\n  # 注释。\n```'), '```yaml\n  # 注释\n```')
eq('prose 代码块字符串句号保留', PR('```ts\nconst s = "完成。"\n```'), '```ts\nconst s = "完成。"\n```')
eq('prose 不删问号', PR('如何调试？\n说明。'), '如何调试？\n说明')
eq('prose 闭合符句号', PR('**重点。**'), '**重点**')
eq('prose 叹号保留', PR('注意！\n完成。'), '注意！\n完成')

-- ── clean_trailing 按 filetype 分派（<leader>c. 代码保守）─────────────────────
local function run_clean_trailing(ft, lines, opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = ft
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  F.clean_trailing(vim.tbl_extend('keep', opts or {}, { silent = true }))
  local out = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  vim.api.nvim_buf_delete(buf, { force = true })
  return out
end

do  -- 代码 buffer：字符串句号毫发无损；行首注释删末尾句号
  local o = run_clean_trailing('typescript', { "const s = '完成。'   ", '// 注释。' })
  eq('ct 代码 字符串句号保留+删空白', o[1], "const s = '完成。'")
  eq('ct 代码 行首注释删句号', o[2], '// 注释')
end
do  -- 散文 buffer：删句号 + 闭合符
  local o = run_clean_trailing('markdown', { '标题。', '**重点。**' })
  eq('ct 散文 删句号', o[1], '标题')
  eq('ct 散文 闭合符', o[2], '**重点**')
end
do  -- Markdown fenced code：围栏内部只清注释行句号
  local o = run_clean_trailing('markdown', {
    '```yaml',
    '  # 注释。',
    '```',
  })
  eq('ct markdown yaml 围栏注释删句号', o[2], '  # 注释')
end
do  -- force_full：代码 buffer 也强制全量（:VVCleanTrailing! 的逃生舱）
  local o = run_clean_trailing('typescript', { '注释。' }, { force_full = true })
  eq('ct force_full 代码也删句号', o[1], '注释')
end

-- buffer 层（<leader>c. 在代码 buffer 上）：同样保护字符串字面量
do
  local o = run_clean_trailing('typescript', {
    'const a = "xx。"',
    "const b = 'xx  。'   ",
    'const c = `xxx 。`',
    '// 注释   ',
  })
  eq('ct lit 双引号串完好',      o[1], 'const a = "xx。"')
  eq('ct lit 单引号串内容留+删尾空格', o[2], "const b = 'xx  。'")
  eq('ct lit 反引号串完好',      o[3], 'const c = `xxx 。`')
  eq('ct lit 注释删尾空格',      o[4], '// 注释')
end

-- ── clean_code（代码层：删行尾句号 + 空白；字符串 / 缩进天然安全；注释句号一并删）──────
local CC = F.clean_code
eq('cc 删行尾句号', CC('保留。'), '保留')
eq('cc 删行尾空白', CC('行尾   '), '行尾')
eq('cc 删行尾句号+空白', CC('行尾。   '), '行尾')
eq('cc 多行', CC('行一  \n保留。'), '行一\n保留')
eq('cc 单引号串句号天然安全(行尾是引号)', CC([[const s = '完成。']]), [[const s = '完成。']])
eq('cc 双引号串安全', CC('const a = "xx。"'), 'const a = "xx。"')
eq('cc 反引号串安全', CC('const c = `xxx 。`'), 'const c = `xxx 。`')
eq('cc 串内 // 不当注释', CC('const u = "http://x。"'), 'const u = "http://x。"')
eq('cc 缩进闭合符不动', CC('  }'), '  }')
eq('cc 串内空格不被吃', CC("local m = '✓ '"), "local m = '✓ '")
eq('cc 行首//注释句号删', CC('// 注释。'), '// 注释')
eq('cc 行首#注释句号删', CC('# 说明。'), '# 说明')
eq('cc 行首--注释句号删', CC('-- 注释。'), '-- 注释')
eq('cc 内联注释句号删(在行尾,安全)', CC('code() // 注释。'), 'code() // 注释')
eq('cc 注释后有闭合符则不删(句号非行尾)', CC('// 注释。)'), '// 注释。)')

-- ── buffer 层 filetype 派注释标记（lua 用 --）──────────────────────────────────
do
  local o = run_clean_trailing('lua', { '-- 注释。', "local s = '完成。'" })
  eq('ct lua 行首注释删句号', o[1], '-- 注释')
  eq('ct lua 字符串句号保留', o[2], "local s = '完成。'")
end

-- ── 配置项 punct 可配置（加入感叹号 → 散文也删叹号）────────────────────────────
do
  F.setup({ punct = { '。', '！' }, commands = false })
  eq('cfg punct 含叹号则删', F.clean_prose('完成！\n好。'), '完成\n好')
  F.setup({ punct = { '。' }, commands = false })
end

-- ── 安全性回归：闭合符不再吃「内部空白」（缩进 / 字符串内空格）──────────────────
-- prose 路径（clean_prose）：删行尾句号 / 闭合符遮挡的句号，但保留缩进与串内空格
eq('safe 缩进+闭合符 不吃缩进', C('  }'), '  }')
eq('safe 缩进右括号', C('    return)'), '    return)')
eq('safe 串内空格不被吃', C("local mark = dry and '· ' or '✓ '"), "local mark = dry and '· ' or '✓ '")
eq('safe 闭合符遮挡句号仍删', C('（说明。）'), '（说明）')
eq('safe prose 缩进不吃', PR('  }'), '  }')
-- code 路径（clean_code）：删行尾句号 + 空白；缩进 / 串内空格 / 串内句号全保留
eq('safe code 缩进不吃', CC('  }'), '  }')
eq('safe code 串内空格保留', CC("const m = '✓ '"), "const m = '✓ '")

-- ── 用户实测场景：sh buffer（代码路径）不破坏缩进 / 串内空格，只删行首#注释句号 ─────
do
  local o = run_clean_trailing('sh', { '  }', "local mark = dry and '· ' or '✓ '", '# 注释。' })
  eq('ct sh 缩进保留', o[1], '  }')
  eq('ct sh 串内空格保留', o[2], "local mark = dry and '· ' or '✓ '")
  eq('ct sh 行首#注释删句号', o[3], '# 注释')
end
-- 即便误走 force_full（prose 路径）：现也只删句号，不再吃缩进 / 串内空格
do
  local o = run_clean_trailing('typescript', { '  }', "const m = '✓ '" }, { force_full = true })
  eq('ct force 缩进保留', o[1], '  }')
  eq('ct force 串内空格保留', o[2], "const m = '✓ '")
end

print(('\n%d 通过, %d 失败'):format(passed, failed))
if failed > 0 then os.exit(1) end
