// 开发设施自身的黑盒回归；不进入插件 tests/，只调用真实共享入口
import assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import {
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const tools = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const utils = resolve(tools, '../..')
const cache = resolve(
  process.env.VV_TEST_DEPS_CACHE
    ?? join(process.env.XDG_CACHE_HOME ?? join(process.env.HOME!, '.cache'), 'nvim-test-deps'),
)

const nvim = Bun.which(process.env.NVIM_BIN ?? 'nvim')
assert(nvim, 'NVIM_BIN 必须指向已安装的 Neovim')

const root = realpathSync(mkdtempSync('/tmp/vv-test-tool-'))
const shared = join(root, 'independent shared checkout')
const plugin = join(root, 'unrelated plugin checkout')
const scratch = join(root, 'scratch')
const evidence = join(root, 'evidence.json')
const bin = join(root, 'bin')

let passed = 0
let failed = 0

function write(path: string, content: string, executable = false) {
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, content, { mode: executable ? 0o755 : 0o644 })
}

function alive(pid: number) {
  try {
    process.kill(pid, 0)
    return true
  }
  catch (error: any) {
    if (error.code === 'ESRCH') {
      return false
    }
    throw error
  }
}

function killGroup(pid: number) {
  try {
    process.kill(-pid, 'SIGKILL')
  }
  catch (error: any) {
    if (error.code !== 'ESRCH') {
      throw error
    }
  }
}

function killTree(pid: number) {
  // Neovim jobstart 子进程自建 session，不能只 kill 外层进程组
  const snapshot = spawnSync('ps', ['-axo', 'pid=,ppid='], { encoding: 'utf8' })
  assert.equal(snapshot.status, 0, snapshot.stderr)

  const rows = snapshot.stdout.trim().split('\n').map((line) => line.trim().split(/\s+/).map(Number))
  const descendants: number[] = []

  function visit(parent: number) {
    for (const [child, owner] of rows) {
      if (owner === parent) {
        visit(child)
        descendants.push(child)
      }
    }
  }

  visit(pid)

  for (const child of descendants) {
    try {
      process.kill(child, 'SIGKILL')
    }
    catch (error: any) {
      if (error.code !== 'ESRCH') {
        throw error
      }
    }
  }

  killGroup(pid)
}

// 专属外层进程组 + 后代快照：墙钟超时也能中断阻塞 RPC
async function run({ filter = '', timeoutMs = 15000, env = {}, launcher = false, signal = false }: RunOptions = {}) {
  const args = launcher ? [join(plugin, 'tests/run.sh'), filter] : [join(shared, 'dev/test/run.sh'), plugin, filter]
  const child = spawn('sh', args, {
    cwd: root,
    detached: true,
    env: {
      ...process.env,
      PATH: `${bin}:${process.env.PATH}`,
      HOME: join(root, 'caller home'),
      XDG_CONFIG_HOME: join(root, 'caller config'),
      XDG_DATA_HOME: join(root, 'caller data'),
      XDG_STATE_HOME: join(root, 'caller state'),
      XDG_CACHE_HOME: join(root, 'caller cache'),
      XDG_RUNTIME_DIR: join(root, 'caller runtime'),
      NVIM_APPNAME: 'nvim',
      VV_TEST_SITE: undefined,
      VV_TEST_VENDOR_ROOT: undefined,
      VV_TEST_LAZY_ROOT: undefined,
      VV_TEST_PACK_ROOT: undefined,
      VV_TEST_RUNTIME_PATHS: undefined,
      VV_UTILS: shared,
      NVIM_BIN: nvim!,
      VV_TEST_DEPS_CACHE: join(root, 'deps'),
      VV_SELFTEST_SCRATCH: scratch,
      VV_SELFTEST_EVIDENCE: evidence,
      ...env,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  })

  let output = ''
  let timedOut = false

  child.stdout.on('data', (chunk) => {
    output += chunk
  })
  child.stderr.on('data', (chunk) => {
    output += chunk
  })

  let signalled = false
  const signalTimer = signal
    ? setInterval(() => {
      if (!signalled && existsSync(evidence)) {
        signalled = true
        process.kill(child.pid!, 'SIGTERM')
      }
    }, 25)
    : undefined
  const timer = setTimeout(() => {
    timedOut = true
    killTree(child.pid!)
  }, timeoutMs)

  try {
    const code = await new Promise<number | null>((done, reject) => {
      child.on('error', reject)
      child.on('close', done)
    })

    return { code, timedOut, output }
  }
  finally {
    clearTimeout(timer)
    if (signalTimer) {
      clearInterval(signalTimer)
    }
    if (child.pid) {
      killGroup(child.pid)
    }
  }
}

const header = `local M = require('mini.test')
local function record(value)
  vim.fn.writefile({ vim.json.encode(value) }, vim.env.VV_SELFTEST_EVIDENCE)
end
`

function fixture(source: string, file = 'test_contract.lua') {
  rmSync(join(plugin, 'tests'), { recursive: true, force: true })
  rmSync(evidence, { force: true })
  write(join(plugin, 'tests', file), header + source)
}

function recorded(): any {
  return JSON.parse(readFileSync(evidence, 'utf8'))
}

function success(result: Awaited<ReturnType<typeof run>>) {
  assert(!result.timedOut, `意外超时\n${result.output}`)
  assert.equal(result.code, 0, result.output)
}

async function test(name: string, body: () => Promise<void>) {
  try {
    await body()
    passed++
    console.log(`PASS: ${name}`)
  }
  catch (error) {
    failed++
    console.error(`FAIL: ${name}\n${error}`)
  }
  finally {
    // 即使清理契约回归导致断言失败，也清理我们记录的 fixture 子进程
    if (existsSync(evidence)) {
      const pid = recorded().pid
      if (pid && alive(pid)) {
        killTree(pid)
      }
    }

    // SIGKILL 不能运行 shell trap；外层拥有 fixture，并负责超时后的清理
    rmSync(scratch, { recursive: true, force: true })
    mkdirSync(scratch, { recursive: true })
  }
}

try {
  mkdirSync(scratch, { recursive: true })
  write(join(root, 'caller config/nvim/init.lua'), 'error(\'设施自测不得加载个人配置\')')

  // 仅加载依赖配置以定位缓存，不调用 ensure_mini_test，不重复维护版本 pin
  const dependency = spawnSync(nvim!, [
    '--headless',
    '-u',
    'NONE',
    '-i',
    'NONE',
    '-n',
    '--cmd',
    `lua io.stdout:write(dofile(${JSON.stringify(join(tools, 'deps.lua'))}).mini_test_commit)`,
    '+qall',
  ], {
    encoding: 'utf8',
    timeout: 5000,
    env: {
      ...process.env,
      XDG_CONFIG_HOME: join(root, 'bootstrap/config'),
      XDG_DATA_HOME: join(root, 'bootstrap/data'),
      XDG_STATE_HOME: join(root, 'bootstrap/state'),
      XDG_CACHE_HOME: join(root, 'bootstrap/cache'),
    },
  })
  assert.equal(dependency.status, 0, dependency.stderr || String(dependency.error))
  const commit = dependency.stdout.trim()

  // 依赖准备与行为验证分开：空缓存时获取固定版本，fixture 阶段仍禁止 Git 与联网
  const miniTestModule = join(cache, 'mini.test', commit, 'lua/mini/test.lua')

  if (!existsSync(miniTestModule)) {
    const prepared = spawnSync(nvim!, [
      '--headless',
      '-u',
      'NONE',
      '-i',
      'NONE',
      '-n',
      '-l',
      join(tools, 'selftest/prepare.lua'),
    ], {
      encoding: 'utf8',
      timeout: 180000,
      env: {
        ...process.env,
        VV_TEST_DEPS_CACHE: cache,
        HOME: join(root, 'bootstrap/home'),
        TMPDIR: root,
        XDG_CONFIG_HOME: join(root, 'bootstrap/config'),
        XDG_DATA_HOME: join(root, 'bootstrap/data'),
        XDG_STATE_HOME: join(root, 'bootstrap/state'),
        XDG_CACHE_HOME: join(root, 'bootstrap/cache'),
      },
    })
    assert.equal(prepared.status, 0, prepared.stderr || prepared.stdout || String(prepared.error))
    if (prepared.stdout) {
      process.stdout.write(prepared.stdout)
    }
  }

  assert(existsSync(miniTestModule), `固定版本 mini.test 缓存准备失败：${cache}`)

  cpSync(join(utils, 'lua'), join(shared, 'lua'), { recursive: true })

  for (const file of ['run.sh', 'run.lua', 'deps.lua', 'paths.sh', 'runtime.lua', 'stop.lua', 'process.lua']) {
    cpSync(join(tools, file), join(shared, 'dev/test', file), { recursive: true })
  }

  cpSync(join(cache, 'mini.test', commit), join(root, 'deps/mini.test', commit), { recursive: true })

  // 不调用 Git，即使缓存接线坏了也不能意外 init/fetch/checkout 或联网
  write(
    join(bin, 'git'),
    '#!/bin/sh\nprintf "selftest 禁止 Git：不应发生任何 Git 调用\\n" >&2\nexit 97\n',
    true,
  )

  // macOS mktemp 的默认路径不保证服从 TMPDIR，显式模板使清理可读回验证
  write(join(bin, 'mktemp'), '#!/bin/sh\nexec /usr/bin/mktemp -d "$VV_SELFTEST_SCRATCH/run.XXXXXX"\n', true)

  await test('断言、清理钩子、收集阶段与子进程退出均不得误报通过', async () => {
    const scenarios = [
      [
        '断言',
        `local T = M.new_set()
T['state 写入可读回'] = function()
  local state = require('vv-utils.state').register('runner', 'assertion')
  assert(state:set('value', 1))
  record({ reached = '断言' })
  M.expect.equality(state:get('value'), 2, { fail_reason = 'selftest 断言失败' })
end
return T`,
        'selftest 断言失败',
      ],
      [
        '清理钩子',
        `local child = M.new_child_neovim()
local T = M.new_set({ hooks = { post_case = function() error('selftest 清理失败') end } })
T['清理失败时 child 仍被收尾'] = function()
  child.start({ '-u', 'NONE', '-i', 'NONE' }, { nvim_executable = vim.v.progpath })
  record({ reached = '清理钩子', pid = child.lua_get('vim.fn.getpid()') })
end
return T`,
        'selftest 清理失败',
      ],
      [
        '收集',
        `record({ reached = '收集' })
error('selftest 收集失败')`,
        'selftest 收集失败',
      ],
      [
        'child 退出',
        `local child = M.new_child_neovim()
local T = M.new_set()
T['child 在真实 RPC 中退出'] = function()
  child.start({ '-u', 'NONE', '-i', 'NONE' }, { nvim_executable = vim.v.progpath })
  record({ reached = 'child 退出', pid = child.lua_get('vim.fn.getpid()') })
  child.lua('os.exit(9)')
end
return T`,
        null,
      ],
    ] as const

    for (const [name, source, diagnostic] of scenarios) {
      fixture(source)
      const result = await run()

      assert(!result.timedOut, `${name} 挂起\n${result.output}`)
      assert.notEqual(result.code, 0, `${name} 报告成功\n${result.output}`)

      const value = recorded()
      assert.equal(value.reached, name, `${name} 未到达预期失败点`)
      if (diagnostic) {
        assert(result.output.includes(diagnostic), result.output)
      }
      if (value.pid) {
        assert(!alive(value.pid), `${name} 泄漏了 Neovim 进程 ${value.pid}`)
      }
      assert.deepEqual(readdirSync(scratch), [], `${name} 泄漏了 shell scratch`)

      console.log(`  ${name}: 非零退出符合预期（${result.code}），scratch 与进程已清理`)
    }
  })

  await test('空集合与未命中字面量过滤器必须失败而非静默通过', async () => {
    fixture('return M.new_set()')
    let result = await run()
    assert(!result.timedOut && result.code !== 0, result.output)
    assert(result.output.includes('no test cases matched'), result.output)

    fixture(`local T = M.new_set()
T['存在'] = function() record({ ran = true }) end
return T`)
    result = await run({ filter: 'absent [literal]' })
    assert(!result.timedOut && result.code !== 0, result.output)
    assert(result.output.includes('no test cases matched'), result.output)
    assert(!existsSync(evidence), '未命中的用例被执行了')
    assert.deepEqual(readdirSync(scratch), [], '未命中运行泄漏了 shell scratch')
  })

  await test('递归命名集合、字面量过滤器与独立路径隔离持久化写入', async () => {
    fixture(
      `local T = M.new_set()
T['嵌套'] = M.new_set()
T['嵌套']['保留 [literal]'] = function()
  assert(vim.fn.getcwd() == vim.env.VV_TEST_REPO, 'runner 未进入插件根目录')
  local paths = {}
  for _, kind in ipairs({ 'config', 'data', 'state', 'cache' }) do
    paths[kind] = vim.fn.stdpath(kind)
    vim.fn.mkdir(paths[kind], 'p')
    assert(vim.fn.writefile({ 'real persistent write' }, paths[kind] .. '/selftest-sentinel') == 0)
    assert(vim.fn.readfile(paths[kind] .. '/selftest-sentinel')[1] == 'real persistent write')
  end
  local state = require('vv-utils.state').register('runner', 'isolation')
  assert(state:get('value') == nil, '上一次调用污染了持久化 state')
  assert(state:set('value', 'saved'))
  assert(state:get('value') == 'saved', '真实 state 写入未能读回')
  record({ paths = paths, repo = vim.env.VV_TEST_REPO, utils = vim.env.VV_UTILS,
    state_file = require('vv-utils.state').default_path() })
end
T['嵌套']['保留 l'] = function() error('字面量过滤器被当作 Lua pattern 处理') end
return T`,
      'deep/test_paths.lua',
    )

    const scratchRoots: string[] = []

    for (let i = 0; i < 2; i++) {
      success(await run({ filter: '[literal]' }))
      const value = recorded()

      assert.equal(value.repo, plugin)
      assert.equal(value.utils, shared)

      for (const path of Object.values(value.paths) as string[]) {
        assert(path.startsWith(scratch + '/'), `持久化路径逃逸出 fixture：${path}`)
        assert(!existsSync(path), `持久化目录在 runner 退出后残留：${path}`)
      }

      assert(!existsSync(value.state_file), '持久化 state 文件在退出后残留')
      scratchRoots.push(dirname(value.paths.state))
      assert.deepEqual(readdirSync(scratch), [], '成功运行泄漏了 scratch')
    }

    assert.notEqual(scratchRoots[0], scratchRoots[1], '两次调用复用了持久化目录')
  })

  // 捕获直接入口未加载依赖声明、HOME 隔离后才找 runtime、覆盖路径被默认值吞掉等回归
  await test('直接入口发现现有依赖、保留路径覆盖并明确拒绝缺失源码', async () => {
    const originalData = join(root, 'installed data')
    const site = join(originalData, 'nvim/site')
    mkdirSync(site, { recursive: true })

    const source = join(root, 'installed source')
    const alternate = join(root, 'alternate source')
    write(join(source, 'lua/selftest_source.lua'), 'return { label = \'default\' }')
    write(join(alternate, 'lua/selftest_source.lua'), 'return { label = \'override\' }')

    fixture(`local T = M.new_set()
T['只读接入已安装源码'] = function()
  assert(vim.env.VV_SELFTEST_SOURCE, '入口没有加载仓库依赖声明')
  vim.opt.runtimepath:prepend(vim.env.VV_SELFTEST_SOURCE)
  record({ label = require('selftest_source').label, site = vim.env.VV_TEST_SITE,
    source = vim.env.VV_SELFTEST_SOURCE, data = vim.fn.stdpath('data') })
end
return T`)
    write(
      join(plugin, 'tests/env.sh'),
      `VV_SELFTEST_SOURCE=$(vv_test_source_path VV_SELFTEST_SOURCE "$VV_TEST_REPO/../installed source")\nexport VV_SELFTEST_SOURCE\n`,
    )

    const env = { XDG_DATA_HOME: originalData, NVIM_APPNAME: 'nvim', VV_TEST_SITE: undefined }
    success(await run({ env: { ...env, VV_SELFTEST_SOURCE: undefined } }))
    assert.equal(recorded().label, 'default')
    assert.equal(recorded().source, source)
    assert.equal(recorded().site, site, 'runtime 应在 HOME/XDG 隔离前发现')
    assert(recorded().data.startsWith(scratch + '/'), '只读接入 runtime 不能取消持久目录隔离')

    success(await run({ env: { ...env, VV_SELFTEST_SOURCE: './alternate source' } }))
    assert.equal(recorded().label, 'override', '必须实际加载覆盖路径的源码')
    assert.equal(recorded().source, alternate, '相对覆盖值应相对调用者 cwd 规范化')

    rmSync(evidence, { force: true })
    const missing = join(root, 'missing source')
    const result = await run({ env: { ...env, VV_SELFTEST_SOURCE: missing } })
    assert(!result.timedOut && result.code !== 0, result.output)
    assert(result.output.includes('VV_SELFTEST_SOURCE') && result.output.includes(missing), result.output)
    assert(!existsSync(evidence), '依赖缺失不能继续执行用例或静默改用默认源码')
  })

  // 真实 launcher 加载不同 fixture 模块捕获优先级错误，不检查源码拼写
  await test('真实薄入口选择开发源码、lazy 与各 native group，并冻结原始路径', async () => {
    const home = join(root, 'false home')
    const config = join(root, 'false config/nvim')
    const data = join(root, 'false data/nvim')
    const vendor = join(root, 'development roots')
    const lazy = join(root, 'custom lazy')
    const pack = join(root, 'custom packpath')
    const runtime = join(root, 'parser query runtime')
    for (const dir of [home, config, data, vendor, lazy, pack, runtime]) {
      mkdirSync(dir, { recursive: true })
    }
    write(join(config, 'init.lua'), `error('personal init must never run')`)
    write(join(runtime, 'lua/selftest_runtime.lua'), 'return \'runtime loaded\'')
    write(join(runtime, 'queries/selftest/highlights.scm'), '; real query root')
    const install = (dir: string, label: string) => {
      cpSync(shared, dir, { recursive: true })
      write(join(dir, 'lua/selftest_utils.lua'), `return ${JSON.stringify(label)}`)
      write(join(dirname(dir), 'fixture-dep/lua/selftest_dep.lua'), `return ${JSON.stringify(label)}`)
    }
    const base: NodeJS.ProcessEnv = {
      HOME: home,
      XDG_CONFIG_HOME: dirname(config),
      XDG_DATA_HOME: dirname(data),
      XDG_CACHE_HOME: join(root, 'false cache'),
      NVIM_APPNAME: 'nvim',
      VV_UTILS: undefined,
      VV_TEST_SITE: undefined,
      VV_TEST_VENDOR_ROOT: vendor,
      VV_TEST_LAZY_ROOT: lazy,
      VV_TEST_PACK_ROOT: pack,
      VV_SELFTEST_DEP: undefined,
      VV_TEST_RUNTIME_PATHS: './parser query runtime',
      // 相对可执行路径必须在随后 cwd/HOME 隔离后仍有效
      NVIM_BIN: './nvim executable',
    }
    write(join(root, 'nvim executable'), `#!/bin/sh\nexec "${nvim}" "$@"\n`, true)
    // 在真实 child 内加载，证明 runtime 同样被接入
    fixture(`local child = M.new_child_neovim()
local T = M.new_set({ hooks = { post_case = function() child.stop() end } })
T['依赖来源与查询根可读回'] = function()
  child.start({ '-u', 'NONE', '-i', 'NONE' }, { nvim_executable = vim.v.progpath })
  child.lua([[vim.opt.packpath = ''
    dofile(vim.env.VV_UTILS .. '/dev/test/runtime.lua').apply()
    vim.opt.runtimepath:prepend(vim.env.VV_UTILS)
    vim.opt.runtimepath:prepend(vim.env.VV_SELFTEST_DEP)]])
  record({ utils = child.lua_get("require('selftest_utils')"),
    dep = child.lua_get("require('selftest_dep')"),
    runtime = child.lua_get("require('selftest_runtime')"),
    query = child.lua_get("vim.api.nvim_get_runtime_file('queries/selftest/highlights.scm', false)[1]"),
    site = vim.env.VV_TEST_SITE })
end
return T`)
    cpSync(join(tools, 'launcher.sh'), join(plugin, 'tests/run.sh'))
    write(join(plugin, 'tests/env.sh'), `vv_test_dependency VV_SELFTEST_DEP fixture-dep lua/selftest_dep.lua\n`)
    const assertLabel = async (label: string, env = base) => {
      const result = await run({ launcher: true, env })
      success(result)
      assert.equal(recorded().utils, label)
      assert.equal(recorded().dep, label)
      assert.equal(recorded().runtime, 'runtime loaded')
      assert.equal(recorded().query, join(runtime, 'queries/selftest/highlights.scm'))
      const expectedData = env.XDG_DATA_HOME ?? join(env.HOME!, '.local/share')
      assert.equal(recorded().site, join(expectedData, 'nvim/site'))
    }
    // 非兄弟标准 lazy 布局与显式 lazy 根分别可用
    install(join(data, 'lazy/vv-utils.nvim'), 'standard lazy')
    const standard = { ...base, VV_TEST_VENDOR_ROOT: undefined, VV_TEST_LAZY_ROOT: undefined, VV_TEST_PACK_ROOT: undefined }
    await assertLabel('standard lazy', standard)
    // 原 HOME 默认值及相对 XDG 缓存必须在隔离前冻结
    install(join(home, '.local/share/nvim/lazy/vv-utils.nvim'), 'HOME lazy')
    cpSync(join(root, 'deps'), join(root, 'relative cache/nvim-test-deps'), { recursive: true })
    await assertLabel('HOME lazy', {
      ...standard,
      XDG_DATA_HOME: undefined,
      XDG_CONFIG_HOME: undefined,
      XDG_CACHE_HOME: './relative cache',
      VV_TEST_DEPS_CACHE: undefined,
    })
    install(join(lazy, 'vv-utils.nvim'), 'custom lazy')
    await assertLabel('custom lazy')
    install(join(root, 'vv-utils.nvim'), 'sibling development')
    await assertLabel('sibling development')
    rmSync(join(root, 'vv-utils.nvim'), { recursive: true })
    rmSync(join(root, 'fixture-dep'), { recursive: true })
    install(join(vendor, 'vv-utils.nvim'), 'dirty development')
    await assertLabel('dirty development')
    write(join(vendor, 'vv-utils.nvim/lua/selftest_utils.lua'), 'return \'dirty changed\'')
    write(join(vendor, 'fixture-dep/lua/selftest_dep.lua'), 'return \'dirty changed\'')
    await assertLabel('dirty changed')
    const override = join(root, 'renamed checkout')
    install(override, 'explicit renamed')
    await assertLabel('explicit renamed', { ...base, VV_UTILS: './renamed checkout', VV_SELFTEST_DEP: './fixture-dep' })
    rmSync(join(root, 'fixture-dep'), { recursive: true })
    rmSync(join(vendor, 'vv-utils.nvim'), { recursive: true })
    rmSync(join(vendor, 'fixture-dep'), { recursive: true })
    rmSync(join(lazy, 'vv-utils.nvim'), { recursive: true })
    rmSync(join(lazy, 'fixture-dep'), { recursive: true })
    for (const location of ['pack/non-core/start', 'pack/another/opt', 'pack/core/opt']) {
      const group = join(pack, location)
      install(join(group, 'vv-utils.nvim'), location)
      await assertLabel(location)
      rmSync(join(pack, 'pack'), { recursive: true })
    }
    // 不传显式 pack 根时，标准 site/core/opt 同样可发现
    rmSync(join(data, 'lazy'), { recursive: true })
    install(join(data, 'site/pack/core/opt/vv-utils.nvim'), 'standard core opt')
    await assertLabel('standard core opt', standard)
    // 无兄弟或显式开发根时，config/vendors 同样可发现
    install(join(config, 'vendors/vv-utils.nvim'), 'config vendors')
    await assertLabel('config vendors', standard)
    for (
      const env of [
        { ...base, VV_UTILS: './missing utils' },
        { ...standard, VV_SELFTEST_DEP: './missing dep' },
        { ...standard, VV_TEST_SITE: './missing site' },
        { ...standard, VV_TEST_PACK_ROOT: './missing pack' },
        { ...standard, VV_TEST_RUNTIME_PATHS: './missing runtime' },
      ]
    ) {
      rmSync(evidence, { force: true })
      const result = await run({ launcher: true, env })
      assert(!result.timedOut && result.code !== 0, result.output)
      assert(result.output.includes('vv-test:'), result.output)
      assert(!existsSync(evidence), '错误覆盖不能 fallback 或运行用例')
    }
    // 目录存在但所需入口标记缺失，同样必须明确失败
    rmSync(join(config, 'vendors/fixture-dep/lua/selftest_dep.lua'))
    const result = await run({ launcher: true, env: standard })
    assert(result.code !== 0 && result.output.includes('missing required marker'), result.output)
  })

  await test('恶意 Git 与终端环境在依赖准备前隔离且真实 Git 不受污染', async () => {
    const realGit = Bun.which('git')!
    const gitBin = join(root, 'real git bin')
    write(join(gitBin, 'git'), `#!/bin/sh\nexec "${realGit}" "$@"\n`, true)
    fixture(`local T = M.new_set()
T['真实 Git 配置不继承注入'] = function()
  for _, key in ipairs({ 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_CONFIG_COUNT',
    'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0', 'GIT_CONFIG_PARAMETERS', 'TMUX', 'TMUX_PANE',
    'STY', 'NVIM', 'NVIM_LISTEN_ADDRESS', 'KITTY_LISTEN_ON', 'KITTY_WINDOW_ID',
    'WEZTERM_PANE' }) do assert(vim.env[key] == nil, key) end
  local result = vim.system({ 'git', 'config', '--get', 'selftest.poison' }, { text = true }):wait()
  assert(result.code == 1 and result.stdout == '', 'Git 仍受个人或命令注入配置污染')
  record({ reached = true })
end
return T`)
    const poison = join(root, 'poison.gitconfig')
    write(poison, '[selftest]\npoison = leaked\n')
    write(
      join(plugin, 'tests/env.sh'),
      `
[ -z "\${GIT_DIR:-}" ] && [ -z "\${GIT_CONFIG_COUNT:-}" ] && [ -z "\${NVIM:-}" ] || exit 92
`,
    )
    success(
      await run({
        env: {
          PATH: `${gitBin}:${bin}:${process.env.PATH}`,
          GIT_DIR: './evil repo',
          GIT_WORK_TREE: './evil tree',
          GIT_INDEX_FILE: './evil index',
          GIT_CONFIG_COUNT: '1',
          GIT_CONFIG_KEY_0: 'selftest.poison',
          GIT_CONFIG_VALUE_0: 'injected',
          GIT_CONFIG_PARAMETERS: '\'selftest.poison=injected\'',
          GIT_CONFIG_GLOBAL: poison,
          GIT_CONFIG_SYSTEM: poison,
          TMUX: 'evil mux',
          TMUX_PANE: '%1',
          STY: 'evil screen',
          KITTY_LISTEN_ON: 'unix:/tmp/evil-kitty',
          KITTY_WINDOW_ID: '42',
          WEZTERM_PANE: '17',
          NVIM: 'evil socket',
          NVIM_LISTEN_ADDRESS: 'evil address',
        },
      }),
    )
    assert.equal(recorded().reached, true)
  })

  await test('相对临时根在切换 cwd 前冻结且真实写入归属本轮 scratch', async () => {
    fixture(`local T = M.new_set()
T['相对 TMPDIR 仍能真实写入隔离目录'] = function()
  for _, name in ipairs({ 'TMPDIR', 'HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME' }) do
    local path = assert(vim.env[name], name)
    assert(path:sub(1, 1) == '/', name .. ' 仍是相对路径：' .. path)
  end
  local file = vim.env.TMPDIR .. '/relative-tmp-proof'
  assert(vim.fn.writefile({ 'owned scratch' }, file) == 0)
  assert(vim.fn.readfile(file)[1] == 'owned scratch')
  record({ temporary_root = vim.env.TMPDIR })
end
return T`)
    const mktemp = join(bin, 'mktemp')
    const original = readFileSync(mktemp, 'utf8')
    // 此场景必须让真实 mktemp 消费入口模板，不能被固定 scratch stub 掩盖
    write(mktemp, '#!/bin/sh\nexec /usr/bin/mktemp "$@"\n', true)
    try {
      success(await run({ env: { TMPDIR: './scratch' } }))
      assert(resolve(recorded().temporary_root).startsWith(scratch + '/'),
        `相对临时根脱离 owning scratch：${recorded().temporary_root}；期望 ${scratch}/`)
      assert.deepEqual(readdirSync(scratch), [], '相对临时根退出后没有完整清理')
    }
    finally {
      write(mktemp, original, true)
    }
  })

  await test('共享入口收到 TERM 后非零退出并清理真实 child 与 scratch', async () => {
    fixture(`local child = M.new_child_neovim()
local T = M.new_set()
T['信号中断真实 RPC'] = function()
  child.start({ '-u', 'NONE', '-i', 'NONE' }, { nvim_executable = vim.v.progpath })
  record({ pid = child.lua_get('vim.fn.getpid()') })
  child.lua('while true do end')
end
return T`)
    const result = await run({ signal: true })
    assert(!result.timedOut, `TERM 清理超时（exit=${result.code}）\n${result.output}`)
    assert.equal(result.code, 143, `TERM 应保留信号退出码（actual=${result.code}）\n${result.output}`)
    assert(!alive(recorded().pid), 'TERM 留下了真实 child')
    assert.deepEqual(readdirSync(scratch), [], 'TERM 未执行 scratch 清理')
  })

  await test('外层墙钟超时终止阻塞 RPC 及其子进程', async () => {
    fixture(`local child = M.new_child_neovim()
local T = M.new_set()
T['阻塞 RPC 无法依赖 runner 事件循环超时'] = function()
  child.start({ '-u', 'NONE', '-i', 'NONE' }, { nvim_executable = vim.v.progpath })
  record({ pid = child.lua_get('vim.fn.getpid()') })
  child.lua('while true do end')
end
return T`)
    const result = await run({ timeoutMs: 2000 })

    assert(result.timedOut, `阻塞 RPC 意外返回\n${result.output}`)
    assert(!alive(recorded().pid), '外层超时后阻塞 child 仍存活')
  })
}
finally {
  console.log(`${passed} PASS / ${failed} FAIL`)
  if (process.env.KEEP === '1') console.log(`fixture retained: ${root}`)
  else rmSync(root, { recursive: true, force: true })
}

process.exitCode = failed ? 1 : 0

/** 内部黑盒入口选项；env 仅覆盖本次启动，不修改父进程环境 */
type RunOptions = {
  filter?: string
  timeoutMs?: number
  env?: NodeJS.ProcessEnv
  launcher?: boolean
  signal?: boolean
}
