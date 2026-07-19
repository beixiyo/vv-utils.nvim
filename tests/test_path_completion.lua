-- 路径补全的 glob 分段、转义、目录过滤与光标范围测试
-- 运行：nvim --headless --clean -l tests/test_path_completion.lua

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.runtimepath:prepend(repo)

local completion = require('vv-utils.path_completion')

local root = vim.fn.tempname()
vim.fn.mkdir(root .. '/packages/core/src', 'p')
vim.fn.mkdir(root .. '/src/components', 'p')
vim.fn.mkdir(root .. '/fixtures/space-dir', 'p')
vim.fn.mkdir(root .. '/cwd-only', 'p')
vim.fn.mkdir(root .. '/.hidden-dir', 'p')
vim.fn.writefile({ 'x' }, root .. '/packages/core/index.ts')
vim.fn.writefile({ 'x' }, root .. '/fixtures/file,name.txt')
vim.fn.writefile({ 'x' }, root .. '/cwd-file.txt')

local passed = 0
local failed = 0

local function test(name, fn)
  local ok, error = pcall(fn)
  if ok then
    passed = passed + 1
    print('PASS: ' .. name)
  else
    failed = failed + 1
    print('FAIL: ' .. name .. ': ' .. tostring(error))
  end
end

local function item(result, word)
  for _, candidate in ipairs(result.items) do
    if candidate.word == word then return candidate end
  end
  error('missing candidate ' .. word .. ': ' .. vim.inspect(result.items))
end

test('只替换光标所在的顶层逗号分段', function()
  local input = '*.{ts,tsx}, ./pack'
  local result = completion.glob(input, { cwd = root })
  assert(result.start_col == #'*.{ts,tsx}, ', result.start_col)
  assert(item(result, './packages/').kind == 'Folder')
end)

test('保留排除前缀和嵌套目录', function()
  local result = completion.glob('!src/co', { cwd = root })
  assert(result.start_col == 0)
  assert(item(result, '!src/components/').kind == 'Folder')
end)

test('保留 ./ 和含空格目录', function()
  local result = completion.glob('./fixtures/sp', { cwd = root })
  assert(item(result, './fixtures/space-dir/').abbr == 'space-dir/')
end)

test('未锚定片段可补全任意深度的路径', function()
  if vim.fn.executable('fd') ~= 1 then return end

  local result = completion.glob('core', { cwd = root })
  assert(item(result, 'packages/core/').kind == 'Folder')
  assert(item(completion.glob('CORE', { cwd = root }), 'packages/core/'))
  assert(item(completion.glob('core/sr', { cwd = root }), 'packages/core/src/'))
end)

test('./ 前缀始终锚定 cwd', function()
  if vim.fn.executable('fd') ~= 1 then return end

  assert(#completion.glob('./core', { cwd = root }).items == 0)
  assert(item(completion.glob('./pack', { cwd = root }), './packages/'))
end)

test('转义文件名中的顶层逗号', function()
  local result = completion.glob('./fixtures/file', { cwd = root })
  assert(item(result, './fixtures/file\\,name.txt').kind == 'File')
end)

test('光标位于输入中间时只读取光标前缀', function()
  local input = './src/co-tail'
  local result = completion.glob(input, { cwd = root, cursor = #'./src/co' })
  assert(result.start_col == 0)
  assert(item(result, './src/components/'))
end)

test('Cwd 补全只返回目录', function()
  local result = completion.directory('cwd-', { cwd = root })
  assert(item(result, 'cwd-only/').kind == 'Folder')
  for _, candidate in ipairs(result.items) do
    assert(candidate.kind == 'Folder', vim.inspect(candidate))
  end
end)

test('空前缀不主动列出隐藏路径', function()
  local result = completion.glob('', { cwd = root })
  for _, candidate in ipairs(result.items) do
    assert(candidate.word ~= '.hidden-dir/')
  end
  assert(item(completion.glob('.h', { cwd = root }), '.hidden-dir/'))
end)

test('通配符之后不提供错误的文件系统候选', function()
  local result = completion.glob('src/*/co', { cwd = root })
  assert(#result.items == 0)
end)

test('无效 cwd 安静返回空候选', function()
  local result = completion.glob('core', { cwd = root .. '/missing' })
  assert(#result.items == 0)
end)

vim.fn.delete(root, 'rf')

print(string.format('%d PASS / %d FAIL', passed, failed))
if failed > 0 then vim.cmd('cquit 1') end
