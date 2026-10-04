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
    if (error.code === 'ESRCH') return false
    throw error
  }
}

function killGroup(pid: number) {
  try {
    process.kill(-pid, 'SIGKILL')
  }
  catch (error: any) {
    if (error.code !== 'ESRCH') throw error
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
      if (error.code !== 'ESRCH') throw error
    }
  }

  killGroup(pid)
}

// 专属外层进程组 + 后代快照：墙钟超时也能中断阻塞 RPC
async function run({ filter = '', timeoutMs = 15000, env = {} }: RunOptions = {}) {
  const child = spawn('sh', [join(shared, 'dev/test/run.sh'), plugin, filter], {
    cwd: root,
    detached: true,
    env: {
      ...process.env,
      PATH: `${bin}:${process.env.PATH}`,
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
    if (child.pid) killGroup(child.pid)
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
      if (pid && alive(pid)) killTree(pid)
    }

    // SIGKILL 不能运行 shell trap；外层拥有 fixture，并负责超时后的清理
    rmSync(scratch, { recursive: true, force: true })
    mkdirSync(scratch, { recursive: true })
  }
}

try {
  mkdirSync(scratch, { recursive: true })

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
      '-u', 'NONE',
      '-i', 'NONE',
      '-n',
      '-l', join(tools, 'selftest/prepare.lua'),
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
    if (prepared.stdout) process.stdout.write(prepared.stdout)
  }

  assert(existsSync(miniTestModule), `固定版本 mini.test 缓存准备失败：${cache}`)

  cpSync(join(utils, 'lua'), join(shared, 'lua'), { recursive: true })

  for (const file of ['run.sh', 'run.lua', 'deps.lua']) {
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
      if (diagnostic) assert(result.output.includes(diagnostic), result.output)
      if (value.pid) assert(!alive(value.pid), `${name} 泄漏了 Neovim 进程 ${value.pid}`)
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
    write(join(source, 'lua/selftest_source.lua'), "return { label = 'default' }")
    write(join(alternate, 'lua/selftest_source.lua'), "return { label = 'override' }")

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
}
