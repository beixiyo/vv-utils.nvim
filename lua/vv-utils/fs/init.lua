-- 文件系统公共入口

local buffer = require('vv-utils.fs.buffer')
local io = require('vv-utils.fs.io')
local operations = require('vv-utils.fs.operations')
local path = require('vv-utils.fs.path')
local transaction = require('vv-utils.fs.transaction')

return {
  exists = path.exists,
  realpath = path.realpath,
  unique_dest = path.unique_dest,

  mkdir_p = operations.mkdir_p,
  create_file = operations.create_file,
  delete = operations.delete,
  rename = operations.rename,
  copy = operations.copy,

  read_all = io.read_all,
  write_all = io.write_all,
  load_json = io.load_json,
  save_json = io.save_json,

  sync_buffers = buffer.sync_buffers,
  new_transaction = transaction.new,
}
