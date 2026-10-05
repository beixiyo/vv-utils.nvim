-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  this = vim.fn.fnamemodify((vim.env.VV_TEST_REPO .. '/tests/test_path.lua'), ':p')
  plugin_root = vim.fn.fnamemodify(this, ':h:h')

  package.path = table.concat({
    plugin_root .. '/lua/?.lua',
    plugin_root .. '/lua/?/init.lua',
    package.path,
  }, ';')

  path = require('vv-utils.path')
end)

T["路径折叠保留前缀、分隔符与可配置层级"] = function()
  child.lua_func(function()
    local function assert_path(name, actual, expected) Helpers.eq(actual, expected, name) end
    assert_path(
      '折叠相对路径的中间层级',
      path.collapse_middle('frontend/electron/renderer/views/cards/[id]/components/CardSummary/index.tsx'),
      'frontend/…/components/CardSummary/index.tsx'
    )

    assert_path(
      '层级未超过限制时保持原样',
      path.collapse_middle('renderer/components/App.tsx'),
      'renderer/components/App.tsx'
    )

    assert_path(
      '保留绝对路径前缀',
      path.collapse_middle('/Users/es/Documents/code/frontend/App.tsx', { head = 1, tail = 2 }),
      '/Users/…/frontend/App.tsx'
    )

    assert_path(
      '支持 Windows 路径分隔符',
      path.collapse_middle([[C:\Users\es\Documents\code\App.tsx]], { head = 1, tail = 2 }),
      [[C:\Users\…\code\App.tsx]]
    )

    assert_path(
      '允许自定义保留层级与省略标记',
      path.collapse_middle('a/b/c/d/e.lua', { head = 2, tail = 1, ellipsis = '...' }),
      'a/b/.../e.lua'
    )

  end)
end

T["项目根优先 Git、兼容 worktree 并回退到语言标记"] = function()
  child.lua_func(function()
    local function assert_path(name, actual, expected) Helpers.eq(actual, expected, name) end
    local fixture = vim.fn.tempname()
    local repository = fixture .. '/repository'
    local frontend = repository .. '/apps/web'
    local source = frontend .. '/src/App.tsx'
    vim.fn.mkdir(frontend .. '/src', 'p')
    vim.fn.mkdir(repository .. '/.git', 'p')
    vim.fn.writefile({ '{}' }, frontend .. '/package.json')
    vim.fn.writefile({ 'export {}' }, source)

    assert_path(
      'Git 根优先于 monorepo 子包 manifest',
      path.find_root(source),
      vim.fs.normalize(repository)
    )

    local standalone = fixture .. '/standalone/service'
    local standalone_source = standalone .. '/lib/main.rs'
    vim.fn.mkdir(standalone .. '/lib', 'p')
    vim.fn.writefile({ '[package]' }, standalone .. '/Cargo.toml')
    vim.fn.writefile({ 'fn main() {}' }, standalone_source)

    assert_path(
      '没有 Git 时回退到最近的语言 manifest',
      path.find_root(standalone_source),
      vim.fs.normalize(standalone)
    )

    assert_path('未命中项目标识时返回 nil', path.find_root(fixture .. '/orphan/file.txt'), nil)

    local worktree = fixture .. '/worktree'
    local worktree_source = worktree .. '/src/main.lua'
    vim.fn.mkdir(worktree .. '/src', 'p')
    vim.fn.writefile({ 'gitdir: ../git/worktrees/test' }, worktree .. '/.git')
    vim.fn.writefile({ 'return {}' }, worktree_source)

    assert_path('支持 worktree 的 .git 文件', path.find_root(worktree_source), vim.fs.normalize(worktree))

    local ignored = fixture .. '/ignored'
    local ignored_source = ignored .. '/src/main.lua'
    vim.fn.mkdir(ignored .. '/src', 'p')
    vim.fn.writefile({ 'build/' }, ignored .. '/.gitignore')
    vim.fn.writefile({ 'return {}' }, ignored_source)

    assert_path('.gitignore 不作为项目根标记', path.find_root(ignored_source), nil)

    vim.fn.delete(fixture, 'rf')
  end)
end

return T
