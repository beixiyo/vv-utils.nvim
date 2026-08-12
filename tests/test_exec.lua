-- vv-utils.exec 的项目入口、shebang 与回退规则回归测试

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
vim.opt.runtimepath:prepend(root)

local Exec = require('vv-utils.exec')
local fixture = vim.fn.tempname()
vim.fn.mkdir(fixture, 'p')

local function write(path, lines)
  vim.fn.writefile(lines, path)
end

local function assert_plan(path, command, cwd, message, opts)
  local plan, err = Exec.resolve(path, opts)
  assert(plan, message .. ': ' .. tostring(err))
  assert(vim.deep_equal(plan.cmd, command), message .. ': command mismatch: ' .. vim.inspect(plan.cmd))
  assert(plan.cwd == cwd, message .. ': cwd mismatch: ' .. tostring(plan.cwd))
  return plan
end

local function assert_error(path, expected, message, opts)
  local plan, err = Exec.resolve(path, opts)
  assert(plan == nil, message .. ': unexpectedly resolved ' .. vim.inspect(plan))
  assert(type(err) == 'string' and err:find(expected, 1, true), message .. ': ' .. tostring(err))
end

-- 项目解析器和默认 runner 使用确定性的 executable 信号测试，不依赖本机安装对应运行时
local original_executable = vim.fn.executable
local available = {
  cargo = true,
  go = true,
  java = true,
  swift = true,
  ['quoted-interpreter'] = true,
  ['fallback-interpreter'] = true,
  ['fallback-runner'] = true,
  ['fallback-rs'] = true,
  ['fallback-go'] = true,
  ['custom-run'] = true,
  [vim.fs.normalize(fixture .. '/relative-runner')] = true,
}
vim.fn.executable = function(command)
  return available[command] and 1 or 0
end

local rust = fixture .. '/rust'
vim.fn.mkdir(rust .. '/src/bin/nested', 'p')
vim.fn.mkdir(rust .. '/examples', 'p')
write(rust .. '/Cargo.toml', { '[package]', 'name = "fixture"', 'version = "0.1.0"' })
write(rust .. '/src/main.rs', { 'fn main() {}' })
write(rust .. '/src/bin/tool.rs', { 'fn main() {}' })
write(rust .. '/src/bin/nested/main.rs', { 'fn main() {}' })
write(rust .. '/src/bin/nested/ignored.rs', { 'fn main() {}' })
write(rust .. '/examples/hello.rs', { 'fn main() {}' })
write(rust .. '/src/lib.rs', { 'pub fn helper() {}' })

assert_plan(rust .. '/src/main.rs', { 'cargo', 'run', '--bin', 'fixture' }, rust, 'Rust 默认 binary')
assert_plan(rust .. '/src/bin/tool.rs', { 'cargo', 'run', '--bin', 'tool' }, rust, 'Rust flat binary')
assert_plan(rust .. '/src/bin/nested/main.rs', { 'cargo', 'run', '--bin', 'nested' }, rust, 'Rust directory binary')
assert_plan(rust .. '/examples/hello.rs', { 'cargo', 'run', '--example', 'hello' }, rust, 'Rust example')
for _, path in ipairs({
  rust .. '/src/main.rs',
  rust .. '/src/bin/tool.rs',
  rust .. '/src/bin/nested/main.rs',
  rust .. '/examples/hello.rs',
}) do
  local plan = assert(Exec.resolve(path))
  assert(plan.target == 'project', 'Rust 项目入口应声明 project target')
end

local rust_module = Exec.resolve(rust .. '/src/lib.rs')
assert(rust_module == nil, 'Rust 非入口模块不可被静默执行')

local rust_default = fixture .. '/rust-default'
vim.fn.mkdir(rust_default .. '/src/bin', 'p')
write(rust_default .. '/Cargo.toml', {
  '[package]',
  'name = "defaulted"',
  'version = "0.1.0"',
  'default-run = "other"',
})
write(rust_default .. '/src/main.rs', { 'fn main() {}' })
write(rust_default .. '/src/bin/other.rs', { 'fn main() {}' })
assert_plan(
  rust_default .. '/src/main.rs',
  { 'cargo', 'run', '--bin', 'defaulted' },
  rust_default,
  'Cargo default-run 不应把 src/main.rs 误导向另一个 binary'
)
assert_plan(
  rust_default .. '/src/bin/other.rs',
  { 'cargo', 'run', '--bin', 'other' },
  rust_default,
  'Cargo 多 binary 应显式选择当前 target'
)

local rust_features = fixture .. '/rust-features'
vim.fn.mkdir(rust_features .. '/src/bin', 'p')
write(rust_features .. '/Cargo.toml', {
  '[package]',
  'name = "featureful"',
  'version = "0.1.0"',
  '',
  '[features]',
  'cli = []',
  'extra = []',
  '',
  '[[bin]]',
  'name = "cli"',
  'path = "src/bin/cli.rs"',
  'required-features = [',
  '  "cli",',
  '  "extra",',
  ']',
})
write(rust_features .. '/src/bin/cli.rs', { 'fn main() {}' })
assert_plan(
  rust_features .. '/src/bin/cli.rs',
  { 'cargo', 'run', '--bin', 'cli', '--features', 'cli,extra' },
  rust_features,
  'Cargo required-features 应随 target 一起传递'
)

local rust_workspace = fixture .. '/rust-workspace'
local rust_member = rust_workspace .. '/member'
vim.fn.mkdir(rust_member .. '/src', 'p')
write(rust_workspace .. '/Cargo.toml', {
  '[workspace]',
  'members = ["member"]',
})
write(rust_member .. '/Cargo.toml', {
  '[package]',
  'name = "member"',
  'version = "0.1.0"',
})
write(rust_member .. '/src/main.rs', { 'fn main() {}' })
assert_plan(
  rust_member .. '/src/main.rs',
  { 'cargo', 'run', '--bin', 'member' },
  rust_member,
  'Cargo virtual workspace 应使用成员 package 的 manifest 和 cwd'
)

local rust_missing = Exec.resolve(rust .. '/src/bin/missing.rs', {
  runners = { rs = { { 'fallback-rs' } } },
})
assert(rust_missing and rust_missing.runner == 'fallback-rs' and rust_missing.cwd == nil,
  'Cargo 不应为缺失的 target 文件生成 project plan')

assert_plan(
  rust .. '/src/main.rs',
  { 'fallback-rs', rust .. '/src/main.rs' },
  nil,
  '禁用 Rust 项目解析器后应回退到扩展名 runner',
  {
    project_runners = { rs = false },
    runners = { rs = { { 'fallback-rs' } } },
  }
)

local go_module = fixture .. '/go-module'
vim.fn.mkdir(go_module .. '/cmd/demo', 'p')
write(go_module .. '/go.mod', { 'module example.com/fixture', '', 'go 1.20' })
write(go_module .. '/cmd/demo/main.go', {
  '// package helper is not a declaration',
  '/* package helper */',
  'package /* an inline comment */ main // trailing comment',
  '',
  'func main() {}',
})
assert_plan(
  go_module .. '/cmd/demo/main.go',
  { 'go', 'run', '.' },
  go_module .. '/cmd/demo',
  'Go package main with comments'
)
assert(Exec.resolve(go_module .. '/cmd/demo/main.go').target == 'project',
  'Go 项目入口应声明 project target')

local go_comment = go_module .. '/cmd/demo/comment.go'
write(go_comment, {
  '/*',
  'package main',
  '*/',
  'package helper',
})
assert_plan(
  go_comment,
  { 'fallback-go', go_comment },
  nil,
  'Go block-comment package main 不得误判',
  { runners = { go = { { 'fallback-go' } } } }
)

local go_string = go_module .. '/cmd/demo/string.go'
write(go_string, {
  'var header = "package main"',
  'package helper',
})
assert_plan(
  go_string,
  { 'fallback-go', go_string },
  nil,
  'Go 字符串中的 package main 不得误判',
  { runners = { go = { { 'fallback-go' } } } }
)

local go_single_root = fixture .. '/go-single'
vim.fn.mkdir(go_single_root, 'p')
local go_single = go_single_root .. '/main.go'
write(go_single, { '// package helper', 'package main // no go.mod', 'func main() {}' })
assert_plan(go_single, { 'go', 'run', go_single }, go_single_root, 'Go 无 module 单文件')

local go_helper = go_module .. '/cmd/demo/helper.go'
write(go_helper, { 'package helper // not executable' })
assert_plan(
  go_helper,
  { 'fallback-go', go_helper },
  nil,
  'Go 非 main package 应回退',
  { runners = { go = { { 'fallback-go' } } } }
)

local go_package_helper = go_module .. '/cmd/demo/package_helper.go'
write(go_package_helper, { 'package main', 'func helper() {}' })
assert_plan(
  go_package_helper,
  { 'go', 'run', '.' },
  go_module .. '/cmd/demo',
  'Go main package 的辅助文件应运行整个 package'
)

local go_build_context_root = fixture .. '/go-build-context'
vim.fn.mkdir(go_build_context_root, 'p')
write(go_build_context_root .. '/go.mod', { 'module example.com/build-context', '', 'go 1.20' })
local go_windows = go_build_context_root .. '/windows.go'
write(go_windows, {
  '//go:build windows',
  '',
  'package main',
  'func main() {}',
})
assert_plan(
  go_windows,
  { 'go', 'run', '.' },
  go_build_context_root,
  'Go build context 应由 go run 处理'
)

local shebang = fixture .. '/quoted.any'
write(shebang, {
  '#!/usr/bin/env -S quoted-interpreter --mode "value with spaces" \'single value\' escaped\\ value',
  'content',
})
assert_plan(
  shebang,
  { 'quoted-interpreter', '--mode', 'value with spaces', 'single value', 'escaped value', shebang },
  nil,
  'env -S 应保留 quoted 参数'
)

local env_shebang = fixture .. '/env.any'
write(env_shebang, { '#!/usr/bin/env fallback-interpreter --flag', 'content' })
assert_plan(
  env_shebang,
  { 'fallback-interpreter', '--flag', env_shebang },
  nil,
  '普通 env shebang 应移除 env'
)

assert_plan(
  shebang,
  { 'fallback-runner', shebang },
  nil,
  'shebang=false 应走扩展名 runner',
  { shebang = false, runners = { any = { { 'fallback-runner' } } } }
)

local swift = fixture .. '/hello.swift'
write(swift, { 'print("swift")' })
assert_plan(swift, { 'swift', swift }, nil, 'Swift runner 不依赖本机安装')

local relative_runner = fixture .. '/relative.any'
write(relative_runner, { 'content' })
assert_plan(
  relative_runner,
  { vim.fs.normalize(fixture .. '/relative-runner'), relative_runner },
  nil,
  '相对 runner 应以绝对路径执行，避免检查目录与执行目录不一致',
  { runners = { any = { { './relative-runner' } } } }
)

local java = fixture .. '/Hello.java'
write(java, { 'class Hello {}' })
assert_plan(java, { 'java', java }, nil, 'Java runner 不依赖本机安装')

local unavailable_shebang = fixture .. '/fallback.foo'
write(unavailable_shebang, { '#!/usr/bin/env -S missing-interpreter --flag', 'content' })
assert_plan(
  unavailable_shebang,
  { 'fallback-runner', unavailable_shebang },
  nil,
  '不可用 shebang 应回退到扩展名 runner',
  { runners = { foo = { { 'fallback-runner' } } } }
)

local custom = fixture .. '/custom.foo'
write(custom, { 'custom project entry' })
assert_plan(
  custom,
  { 'custom-run', custom },
  nil,
  '自定义项目解析器可省略 cwd',
  {
    project_runners = {
      foo = function(path)
        return { cmd = { 'custom-run', path }, runner = 'custom' }
      end,
    },
  }
)

local no_extension = fixture .. '/no_extension'
write(no_extension, { 'content' })
assert_error('', 'empty path', '空路径错误')
assert_error(no_extension, 'no shebang and no matching extension', '无扩展名错误')
assert_error(
  fixture .. '/missing.foo',
  'no available runner',
  '无可用 runner 错误',
  { runners = { foo = { { 'missing-runner' } } } }
)

vim.fn.executable = original_executable

local example = fixture .. '/example.txt'
write(example, { 'example' })
local cancelled = false
Exec.confirm.open({
  path = example,
  cmd = { 'example-runner', example },
  on_confirm = function() end,
  on_cancel = function() cancelled = true end,
})
local confirm_window = vim.api.nvim_get_current_win()
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
assert(not vim.api.nvim_win_is_valid(confirm_window) and cancelled,
  'exec 确认适配器应转发真实取消动作')

vim.fn.delete(fixture, 'rf')
print('vv-utils exec: PASS')
