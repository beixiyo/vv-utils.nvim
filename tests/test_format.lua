-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  this = vim.fn.fnamemodify((vim.env.VV_TEST_REPO .. '/tests/test_format.lua'), ':p')
  plugin_root = vim.fn.fnamemodify(this, ':h:h')
  package.path = plugin_root .. '/lua/?.lua;' .. plugin_root .. '/lua/?/init.lua;' .. package.path

  F = require('vv-utils.format')
  function run_clean_trailing(ft, lines, opts)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = ft
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    F.clean_trailing(vim.tbl_extend('keep', opts or {}, { silent = true }))
    local out = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    vim.api.nvim_buf_delete(buf, { force = true })
    return out
  end
end)

T["中英文、数字与 Markdown 边界插入空格"] = function()
  child.lua_func(function()
    eq = function(name, got, want) Helpers.eq(got, want, name) end
    local A, C, PR, CC = F.add_spaces_around_english, F.clean_prose, F.clean_prose, F.clean_code
    local A = F.add_spaces_around_english

    eq('基础 我喜欢apple', A('我喜欢apple'), '我喜欢 apple')
    eq('基础 apple很好吃', A('apple很好吃'), 'apple 很好吃')
    eq('基础 这是一个test', A('这是一个test'), '这是一个 test')
    eq('基础 hello世界', A('hello世界'), 'hello 世界')

    eq('数字 完成率100', A('完成率100'), '完成率 100')
    eq('数字 100完成', A('100完成'), '100 完成')
    eq('数字 这是2026年', A('这是2026年'), '这是 2026 年')

    eq('前缀符号 @frps', A('你的用户名@frps的公网'), '你的用户名 @frps 的公网')
    eq('前缀符号 #tag', A('搜索#tag标签'), '搜索 #tag 标签')
    eq('前缀符号 $100', A('金额$100美元'), '金额 $100 美元')

    eq('后缀符号 100%', A('完成100%成功'), '完成 100% 成功')
    eq('后缀符号 30°', A('温度是30°今天'), '温度是 30° 今天')
    eq('后缀符号 C++', A('C++教程'), 'C++ 教程')

    eq('Markdown **bold**', A('测试**bold**测试'), '测试 **bold** 测试')
    eq('Markdown _italic_', A('测试_italic_测试'), '测试 _italic_ 测试')
    eq('Markdown `code`', A('测试`code`测试'), '测试 `code` 测试')
    eq('Markdown 链接', A('参考[Google](https://google.com)搜索'), '参考 [Google](https://google.com) 搜索')

    eq('混合符号 arch+@frps+IP', A('你的arch用户名@frps的公网IP或域名'), '你的 arch 用户名 @frps 的公网 IP 或域名')
    eq('混合符号 _lodash_ _map_', A('使用_lodash_库的_map_方法'), '使用 _lodash_ 库的 _map_ 方法')
  end)
end

T["散文句号清理保留闭合符与字符串空白"] = function()
  child.lua_func(function()
    eq = function(name, got, want) Helpers.eq(got, want, name) end
    local A, C, PR, CC = F.add_spaces_around_english, F.clean_prose, F.clean_prose, F.clean_code
    local C = F.clean_prose

    eq('清理 单句号', C('这是一句话。'), '这是一句话')
    eq('清理 多句号', C('结束。。。'), '结束')
    eq('清理 句号+空格', C('完成。   '), '完成')
    eq('清理 句号+tab', C('完成。\t'), '完成')
    eq('清理 叹号默认保留', C('好的！'), '好的！')
    eq('清理 问号默认保留', C('对吗？'), '对吗？')
    eq('清理 纯空格', C('hello   '), 'hello')
    eq('清理 纯tab', C('hello\t\t'), 'hello')
    eq('清理 中间不动', C('A。B。'), 'A。B')
    eq('清理 多行', C('行一。\n行二！  \n  无尾  '), '行一\n行二！\n  无尾')
    eq('清理 无变化', C('普通文本'), '普通文本')

    -- 句号被行尾闭合符挡住：删句号、保留闭合符
    eq('清理 闭合符 **加粗。**', C('**重点。**'), '**重点**')
    eq('清理 闭合符 *斜体。*', C('*斜体。*'), '*斜体*')
    eq('清理 闭合符 行内代码`。', C('看 `code`。'), '看 `code`')
    eq('清理 闭合符 括号内（。）', C('（说明。）'), '（说明）')
    eq('清理 闭合符 括号外（）。', C('（说明）。'), '（说明）')
    eq('清理 闭合符 引号。"', C('他说。"'), '他说"')
    eq('清理 闭合符 中文引号。”', C('他说。”'), '他说”')
    eq('清理 闭合符无句号不变', C('**加粗**'), '**加粗**')
    eq('清理 闭合符前中间句号保留', C('A。B**'), 'A。B**')
    eq('清理 多行含闭合符', C('一。**\n二`x`。\n三'), '一**\n二`x`\n三')

    -- ── clean_prose（批量散文：代码围栏内只清注释行句号；围栏外仅删句号，不删 ？！）──
    local PR = F.clean_prose
    eq('散文 代码块普通文本保留句号', PR('文本。\n```\n代码。\n```\n结尾。'), '文本\n```\n代码。\n```\n结尾')
    eq('散文 yaml 代码块注释删句号', PR('```yaml\n  # 注释。\n```'), '```yaml\n  # 注释\n```')
    eq('散文 代码块字符串句号保留', PR('```ts\nconst s = "完成。"\n```'), '```ts\nconst s = "完成。"\n```')
    eq('散文 不删问号', PR('如何调试？\n说明。'), '如何调试？\n说明')
    eq('散文 闭合符句号', PR('**重点。**'), '**重点**')
    eq('散文 叹号保留', PR('注意！\n完成。'), '注意！\n完成')
  end)
end

T["按文件类型清理行尾且不破坏代码字符串"] = function()
  child.lua_func(function()
    eq = function(name, got, want) Helpers.eq(got, want, name) end
    local A, C, PR, CC = F.add_spaces_around_english, F.clean_prose, F.clean_prose, F.clean_code
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
      eq('行尾清理 代码 字符串句号保留+删空白', o[1], "const s = '完成。'")
      eq('行尾清理 代码 行首注释删句号', o[2], '// 注释')
    end
    do  -- 散文 buffer：删句号 + 闭合符
      local o = run_clean_trailing('markdown', { '标题。', '**重点。**' })
      eq('行尾清理 散文 删句号', o[1], '标题')
      eq('行尾清理 散文 闭合符', o[2], '**重点**')
    end
    do  -- Markdown fenced code：围栏内部只清注释行句号
      local o = run_clean_trailing('markdown', {
        '```yaml',
        '  # 注释。',
        '```',
      })
      eq('行尾清理 markdown yaml 围栏注释删句号', o[2], '  # 注释')
    end
    do  -- force_full：代码 buffer 也强制全量（:VVCleanTrailing! 的逃生舱）
      local o = run_clean_trailing('typescript', { '注释。' }, { force_full = true })
      eq('行尾清理 force_full 代码也删句号', o[1], '注释')
    end

    -- buffer 层（<leader>c. 在代码 buffer 上）：同样保护字符串字面量
    do
      local o = run_clean_trailing('typescript', {
        'const a = "xx。"',
        "const b = 'xx  。'   ",
        'const c = `xxx 。`',
        '// 注释   ',
      })
      eq('行尾清理 lit 双引号串完好',      o[1], 'const a = "xx。"')
      eq('行尾清理 lit 单引号串内容留+删尾空格', o[2], "const b = 'xx  。'")
      eq('行尾清理 lit 反引号串完好',      o[3], 'const c = `xxx 。`')
      eq('行尾清理 lit 注释删尾空格',      o[4], '// 注释')
    end
  end)
end

T["代码注释标记、块注释与多语言保护"] = function()
  child.lua_func(function()
    eq = function(name, got, want) Helpers.eq(got, want, name) end
    local A, C, PR, CC = F.add_spaces_around_english, F.clean_prose, F.clean_prose, F.clean_code
    local CC = F.clean_code
    eq('代码清理 删行尾句号', CC('保留。'), '保留')
    eq('代码清理 删行尾空白', CC('行尾   '), '行尾')
    eq('代码清理 删行尾句号+空白', CC('行尾。   '), '行尾')
    eq('代码清理 多行', CC('行一  \n保留。'), '行一\n保留')
    eq('代码清理 单引号串句号天然安全(行尾是引号)', CC([[const s = '完成。']]), [[const s = '完成。']])
    eq('代码清理 双引号串安全', CC('const a = "xx。"'), 'const a = "xx。"')
    eq('代码清理 反引号串安全', CC('const c = `xxx 。`'), 'const c = `xxx 。`')
    eq('代码清理 串内 // 不当注释', CC('const u = "http://x。"'), 'const u = "http://x。"')
    eq('代码清理 缩进闭合符不动', CC('  }'), '  }')
    eq('代码清理 串内空格不被吃', CC("local m = '✓ '"), "local m = '✓ '")
    eq('代码清理 行首//注释句号删', CC('// 注释。'), '// 注释')
    eq('代码清理 行首#注释句号删', CC('# 说明。'), '# 说明')
    eq('代码清理 行首--注释句号删', CC('-- 注释。'), '-- 注释')
    eq('代码清理 内联注释句号删(在行尾,安全)', CC('code() // 注释。'), 'code() // 注释')
    eq('代码清理 注释后有闭合符则不删(句号非行尾)', CC('// 注释。)'), '// 注释。)')

    -- ── buffer 层 filetype 派注释标记（lua 用 --）──────────────────────────────────
    do
      local o = run_clean_trailing('lua', { '-- 注释。', "local s = '完成。'" })
      eq('行尾清理 lua 行首注释删句号', o[1], '-- 注释')
      eq('行尾清理 lua 字符串句号保留', o[2], "local s = '完成。'")
    end

    -- ── 块注释结束符遮挡的句号（/** */、{/* */}、<!-- -->、--[[ ]]）────────────────────
    do
      local o = run_clean_trailing('typescript', {
        '/** 读取上一次真正退出时留下的安装意图。 */',
        '/**',
        ' * 多行文档注释。',
        ' * 结束行也带句号。 */',
        'const a = 1 /* 行尾块注释。 */',
        '/*紧贴结束符。*/',
        'const re = /完成。*/',
        "const s = '完成。*/'",
        '// 注释。)',
      })
      eq('ts jsdoc 单行', o[1], '/** 读取上一次真正退出时留下的安装意图 */')
      eq('ts jsdoc 多行正文', o[3], ' * 多行文档注释')
      eq('ts jsdoc 多行结束行', o[4], ' * 结束行也带句号 */')
      eq('ts 行尾块注释', o[5], 'const a = 1 /* 行尾块注释 */')
      eq('ts 无空白块注释', o[6], '/*紧贴结束符*/')
      eq('ts 正则字面量不动', o[7], 'const re = /完成。*/')
      eq('ts 字符串内 */ 不动', o[8], "const s = '完成。*/'")
      eq('ts // 注释。) 保守不删', o[9], '// 注释。)')
    end
    do
      local o = run_clean_trailing('typescriptreact', {
        '{/* JSX 注释。 */}',
        '      {/* 缩进 JSX 注释。*/}',
        '/** 组件说明。 */',
      })
      eq('TSX 注释', o[1], '{/* JSX 注释 */}')
      eq('tsx 缩进无空白 {/* */}', o[2], '      {/* 缩进 JSX 注释*/}')
      eq('tsx jsdoc', o[3], '/** 组件说明 */')
    end
    do
      local o = run_clean_trailing('css', { '/* 样式说明。 */', '.a { color: red; } /* 行尾。 */' })
      eq('css 块注释', o[1], '/* 样式说明 */')
      eq('css 行尾块注释', o[2], '.a { color: red; } /* 行尾 */')
    end
    do
      local o = run_clean_trailing('scss', { '// 单行。', '/* 块。 */' })
      eq('SCSS 单行注释', o[1], '// 单行')
      eq('scss 块', o[2], '/* 块 */')
    end
    do
      local o = run_clean_trailing('vue', { '<!-- 模板注释。 -->', '<div /> <!-- 行尾。 -->' })
      eq('vue html 注释', o[1], '<!-- 模板注释 -->')
      eq('vue 行尾 html 注释', o[2], '<div /> <!-- 行尾 -->')
    end
    do
      local o = run_clean_trailing('html', { '<!--紧贴。-->' })
      eq('html 无空白注释', o[1], '<!--紧贴-->')
    end
    do
      local o = run_clean_trailing('lua', {
        '--[[ 块注释。 ]]',
        '--[==[ 等号块注释。 ]==]',
        "local s = [[ 长字符串。 ]]",
        '---@param x string 参数说明。',
      })
      eq('Lua 普通块注释', o[1], '--[[ 块注释 ]]')
      eq('Lua 等号块注释', o[2], '--[==[ 等号块注释 ]==]')
      eq('lua 长字符串不动', o[3], "local s = [[ 长字符串。 ]]")
      eq('lua ---@ 注解', o[4], '---@param x string 参数说明')
    end
    do
      local o = run_clean_trailing('c', { 'int a; /* C 注释。 */' })
      eq('c 块注释', o[1], 'int a; /* C 注释 */')
    end
    do
      local o = run_clean_trailing('python', { '# 注释。', '"""文档字符串。"""' })
      eq('Python 行首注释', o[1], '# 注释')
      eq('python docstring 是字符串，不动', o[2], '"""文档字符串。"""')
    end
    do  -- 散文 buffer：Markdown 里的 HTML 注释
      local o = run_clean_trailing('markdown', { '<!-- 隐藏说明。 -->', '正文。' })
      eq('Markdown html 注释', o[1], '<!-- 隐藏说明 -->')
      eq('Markdown 正文', o[2], '正文')
    end
    do  -- Markdown 围栏内的块注释
      local o = run_clean_trailing('markdown', {
        '```tsx',
        '/** 说明。 */',
        '/**',
        ' * 续行。',
        ' */',
        '{/* JSX。 */}',
        'const re = /完成。*/',
        '```',
        '```css',
        '/* 样式。 */',
        '```',
        '```html',
        '<!-- 注释。 -->',
        '```',
      })
      eq('代码围栏 jsdoc 单行', o[2], '/** 说明 */')
      eq('代码围栏 jsdoc 续行', o[4], ' * 续行')
      eq('代码围栏 jsx 注释', o[6], '{/* JSX */}')
      eq('代码围栏 正则字面量不动', o[7], 'const re = /完成。*/')
      eq('代码围栏 css 注释', o[10], '/* 样式 */')
      eq('代码围栏 html 注释', o[13], '<!-- 注释 -->')
    end
  end)
end

T["标点配置与缩进、内部空格安全回归"] = function()
  child.lua_func(function()
    eq = function(name, got, want) Helpers.eq(got, want, name) end
    local A, C, PR, CC = F.add_spaces_around_english, F.clean_prose, F.clean_prose, F.clean_code
    do
      F.setup({ punct = { '。', '！' }, commands = false })
      eq('配置 punct 含叹号则删', F.clean_prose('完成！\n好。'), '完成\n好')
      F.setup({ punct = { '。' }, commands = false })
    end

    -- ── 安全性回归：闭合符不再吃「内部空白」（缩进 / 字符串内空格）──────────────────
    -- prose 路径（clean_prose）：删行尾句号 / 闭合符遮挡的句号，但保留缩进与串内空格
    eq('安全 缩进+闭合符 不吃缩进', C('  }'), '  }')
    eq('安全 缩进右括号', C('    return)'), '    return)')
    eq('安全 串内空格不被吃', C("local mark = dry and '· ' or '✓ '"), "local mark = dry and '· ' or '✓ '")
    eq('安全 闭合符遮挡句号仍删', C('（说明。）'), '（说明）')
    eq('安全 prose 缩进不吃', PR('  }'), '  }')
    -- code 路径（clean_code）：删行尾句号 + 空白；缩进 / 串内空格 / 串内句号全保留
    eq('安全 code 缩进不吃', CC('  }'), '  }')
    eq('安全 code 串内空格保留', CC("const m = '✓ '"), "const m = '✓ '")

    -- ── 用户实测场景：sh buffer（代码路径）不破坏缩进 / 串内空格，只删行首#注释句号 ─────
    do
      local o = run_clean_trailing('sh', { '  }', "local mark = dry and '· ' or '✓ '", '# 注释。' })
      eq('行尾清理 sh 缩进保留', o[1], '  }')
      eq('行尾清理 sh 串内空格保留', o[2], "local mark = dry and '· ' or '✓ '")
      eq('行尾清理 sh 行首#注释删句号', o[3], '# 注释')
    end
    -- 即便误走 force_full（prose 路径）：现也只删句号，不再吃缩进 / 串内空格
    do
      local o = run_clean_trailing('typescript', { '  }', "const m = '✓ '" }, { force_full = true })
      eq('行尾清理 force 缩进保留', o[1], '  }')
      eq('行尾清理 force 串内空格保留', o[2], "const m = '✓ '")
    end
  end)
end

return T
