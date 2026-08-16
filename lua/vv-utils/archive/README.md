# vv-utils.archive

跨平台 tar 归档读取与解压，依赖系统中的 `tar` 或 `bsdtar`

模块只提供归档机制，不负责下载、版本选择、哈希校验、manifest 解释或最终目录发布。调用方应先验证可信来源或文件哈希，再解压到自己创建的空 staging 目录

```lua
local archive = require('vv-utils.archive')

local cancel = archive.extract({
  archive = '/tmp/dict.tar.gz',
  destination = '/tmp/vv-translate-staging',
}, function(result)
  if not result.ok then
    vim.notify(result.message, vim.log.levels.ERROR)
    return
  end

  vim.notify(('Extracted %d entries'):format(#result.entries))
end)

-- 按需取消，取消后不会再调用 callback
cancel()
```

## API

- `resolve(commands?)`：按顺序选择可执行的 `tar` / `bsdtar`
- `validate(entries)`：拒绝绝对路径、盘符路径、`..` 逃逸和 Windows ADS 路径
- `list(opts, callback)`：通过 `tar -tf` 异步列出成员
- `extract(opts, callback)`：先列出并校验成员，再通过 `tar -xf` 解压

`list` / `extract` 的 callback 始终在后续主循环异步投递，包括参数和环境预检失败；返回的 `cancel()` 可以压制尚未投递的结果

`extract` 要求目标目录已存在且为空，避免意外覆盖调用方数据。路径校验不替代内容可信性校验，也不承诺防御恶意归档中的所有文件系统对象
