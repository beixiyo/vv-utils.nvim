-- 场景独立运行，收集阶段只注册 mini.test 具名用例与生命周期 hook。
local H = dofile('tests/helpers.lua')
local T, child = H.new_set(function()
  this = vim.fn.fnamemodify((vim.env.VV_TEST_REPO .. '/tests/test_fs_operations.lua'), ':p')
  plugin_root = vim.fn.fnamemodify(this, ':h:h')

  package.path = table.concat({
    plugin_root .. '/lua/?.lua',
    plugin_root .. '/lua/?/init.lua',
    package.path,
  }, ';')

  Highlight = require('vv-utils.fs.file_info_highlight')
  Io = require('vv-utils.fs.io')
  Operations = require('vv-utils.fs.operations')
  Path = require('vv-utils.fs.path')
  Probe = require('vv-utils.fs.file_probe')
  Render = require('vv-utils.fs.file_render')
  -- macOS 的 tempname 位于 /var（指向 /private/var 的符号链接），先解析真实路径，
  -- 避免与被测代码返回的 realpath 不一致
  fixture = vim.fn.tempname()
  vim.fn.mkdir(fixture, 'p')
  fixture = assert(vim.uv.fs_realpath(fixture))
  upper = fixture .. '/README.MD'
  lower = fixture .. '/README.md'
end)

T["目录判定与符号链接路径遵循文件系统语义"] = function()
  child.lua_func(function()
    vim.fn.mkdir(fixture, 'p')
    vim.fn.writefile({ 'content' }, upper)

    assert(Path.is_directory(fixture), 'fixture 应识别为目录')
    assert(not Path.is_directory(upper), '普通文件不应识别为目录')
    assert(Path.is_dir_empty(fixture) == false, '包含文件的目录不应为空')

    local real_target = fixture .. '/real-target/file.txt'
    vim.fn.mkdir(vim.fs.dirname(real_target), 'p')
    vim.fn.writefile({ 'target' }, real_target)
    local existing_link = fixture .. '/existing-link'
    assert(vim.uv.fs_symlink('real-target/file.txt', existing_link))
    assert(Path.realpath(existing_link) == vim.fs.normalize(real_target),
      '已有符号链接必须解析到真实目标')

    local broken_parent = fixture .. '/broken-parent'
    vim.fn.mkdir(broken_parent, 'p')
    local broken_link = broken_parent .. '/broken-link'
    assert(vim.uv.fs_symlink('missing/leaf', broken_link))
    assert(Path.realpath(broken_link) == vim.fs.normalize(broken_parent .. '/missing/leaf'),
      '失效相对符号链接必须相对自身父目录解析')
    assert(Path.realpath(broken_link .. '/../sibling') == vim.fs.normalize(broken_parent .. '/missing/sibling'),
      '输入路径必须先解析失效符号链接再处理上级目录')

    local layered_link = broken_parent .. '/layer-1'
    assert(vim.uv.fs_symlink('layer-2', layered_link))
    assert(vim.uv.fs_symlink('missing-final', broken_parent .. '/layer-2'))
    assert(Path.realpath(layered_link) == vim.fs.normalize(broken_parent .. '/missing-final'),
      '多层失效符号链接必须逐层解析相对目标')

    local symlink_target_parent = broken_parent .. '/real/sub'
    vim.fn.mkdir(symlink_target_parent, 'p')
    assert(vim.uv.fs_symlink('real/sub', broken_parent .. '/ancestor-link'))
    local nested_target_link = broken_parent .. '/nested-target'
    assert(vim.uv.fs_symlink('ancestor-link/../missing-final', nested_target_link))
    assert(Path.realpath(nested_target_link) == vim.fs.normalize(broken_parent .. '/real/missing-final'),
      '失效链接目标必须先解析祖先符号链接再处理上级目录')

    local loop_a = broken_parent .. '/loop-a'
    local loop_b = broken_parent .. '/loop-b'
    assert(vim.uv.fs_symlink('loop-b', loop_a))
    assert(vim.uv.fs_symlink('loop-a', loop_b))
    assert(Path.realpath(loop_a) == vim.fs.normalize(loop_a),
      '符号链接环路必须终止并返回规范化未解析路径')

    local missing_descendant = broken_parent .. '/missing/child'
    assert(Path.realpath(missing_descendant) == vim.fs.normalize(missing_descendant),
      '不存在路径必须保留最长已有祖先')

    local empty_dir = fixture .. '/empty'
    vim.fn.mkdir(empty_dir)
    assert(Path.is_dir_empty(empty_dir) == true, '空目录应识别为空')
    local empty, empty_error = Path.is_dir_empty(upper)
    assert(empty == nil and empty_error:match('not a directory'), '非目录应返回可读错误')
  end)
end

T["仅大小写改名不丢内容且拒绝覆盖已有文件"] = function()
  child.lua_func(function()
    vim.fn.mkdir(fixture, 'p')
    vim.fn.writefile({ 'content' }, upper)

    Operations.rename(upper, lower)

    assert(vim.fn.filereadable(lower) == 1, '仅大小写重命名后应保留目标文件名')
    assert(vim.fn.readfile(lower)[1] == 'content', '仅大小写重命名不应改变文件内容')

    local source = fixture .. '/source.txt'
    local existing = fixture .. '/existing.txt'
    vim.fn.writefile({ 'source' }, source)
    vim.fn.writefile({ 'existing' }, existing)

    local ok, err = pcall(Operations.rename, source, existing)
    assert(not ok and tostring(err):match('target exists'), '重命名仍应拒绝不同的已存在目标')
    assert(vim.fn.readfile(existing)[1] == 'existing', '重命名不应覆盖不同的已存在目标')
  end)
end

T["Mach-O 元信息、展示与高亮"] = function()
  child.lua_func(function()
    local macho = fixture .. '/extensionless'
    local macho_header = string.char(
      0xcf, 0xfa, 0xed, 0xfe,
      0x0c, 0x00, 0x00, 0x01,
      0x00, 0x00, 0x00, 0x00,
      0x02, 0x00, 0x00, 0x00
    ) .. string.rep('\0', 64)
    Io.write_all(macho, macho_header, { mode = 493 })

    local macho_info = Probe.inspect(macho)
    assert(macho_info.binary, '无扩展名 Mach-O 可执行文件应按内容识别')
    assert(macho_info.kind == 'Mach-O 64-bit executable', 'Mach-O 类型应由文件头识别')
    assert(macho_info.architecture == 'arm64', 'Mach-O 架构应由 CPU 类型识别')
    assert(macho_info.executable, '应报告可执行权限')
    local info_lines = Render.lines(macho_info, { display_path = 'target/debug/vv-mcp' })
    assert(info_lines[1] == 'Binary file', '二进制信息应使用共享英文标题')
    assert(vim.tbl_contains(info_lines, 'Path: target/debug/vv-mcp'), '二进制信息应包含展示路径')
    assert(vim.tbl_contains(info_lines, 'Type: Mach-O 64-bit executable'), '二进制信息应包含文件类型')
    assert(vim.tbl_contains(info_lines, 'Architecture: arm64'), '二进制信息应包含架构')
    assert(vim.tbl_contains(info_lines, 'Executable: Yes'), '二进制信息应包含可执行状态')

    local info_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(info_buf, 0, -1, false, info_lines)
    assert(Highlight.apply(info_buf), '二进制信息高亮应可应用到有效缓冲区')
    local highlighted = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(info_buf, -1, 0, -1, { details = true })) do
      highlighted[mark[4].hl_group] = true
    end
    assert(highlighted.VVUtilsFileInfoTitle, '应存在二进制信息标题高亮')
    assert(highlighted.VVUtilsFileInfoLabel, '应存在二进制信息标签高亮')
    assert(highlighted.VVUtilsFileInfoPath, '应存在二进制信息路径高亮')
    assert(highlighted.VVUtilsFileInfoPositive, '应存在二进制信息正向状态高亮')
    vim.api.nvim_buf_delete(info_buf, { force = true })
  end)
end

T["私有写入权限与文本、二进制覆盖探测"] = function()
  child.lua_func(function()
    local private_dir = fixture .. '/private/nested'
    local private_file = private_dir .. '/history.json'
    Io.write_all(private_file, '{"ok":true}\n', { mode = 384, directory_mode = 448 })
    assert(Io.read_all(private_file) == '{"ok":true}\n', '私有文件写入后应能读回原始内容')
    assert(assert(vim.uv.fs_stat(private_file)).mode % 512 == 384, '私有文件权限应为 0600')
    assert(assert(vim.uv.fs_stat(private_dir)).mode % 512 == 448, '新建父目录权限应为 0700')

    local script = fixture .. '/script'
    Io.write_all(script, '#!/bin/sh\necho ok\n', { mode = 493 })
    assert(not Probe.is_binary(script), '无扩展名的文本可执行文件不应识别为二进制')

    local allowed = fixture .. '/allowed.bin'
    Io.write_all(allowed, 'binary\0content')
    assert(
      not Probe.is_binary(allowed, { extensions = { bin = false } }),
      '显式 false 扩展名覆盖应跳过内容探测'
    )

    local forced = fixture .. '/forced.asset'
    Io.write_all(forced, 'plain content')
    local forced_info = Probe.inspect(forced, { extensions = { asset = true } })
    assert(forced_info.binary, '显式 true 扩展名覆盖应强制识别为二进制')
    assert(forced_info.kind == 'Binary data', '强制二进制元信息不应继续报告文本类型')
  end)
end

return T
