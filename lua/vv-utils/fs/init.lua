-- 文件系统公共入口

local buffer = require('vv-utils.fs.buffer')
local io = require('vv-utils.fs.io')
local operations = require('vv-utils.fs.operations')
local delete_async = require('vv-utils.fs.delete_async')
local path = require('vv-utils.fs.path')
local temp = require('vv-utils.fs.temp')
local transaction = require('vv-utils.fs.transaction')

return {
  exists = path.exists,
  is_directory = path.is_directory,
  is_dir_empty = path.is_dir_empty,
  realpath = path.realpath,
  unique_dest = path.unique_dest,

  mkdir_p = operations.mkdir_p,
  create_file = operations.create_file,
  delete = operations.delete,
  delete_async = delete_async.delete_async,
  rename = operations.rename,
  copy = operations.copy,

  read_all = io.read_all,
  write_all = io.write_all,
  load_json = io.load_json,
  save_json = io.save_json,
  temp = temp,

  sync_buffers = buffer.sync_buffers,
  close_stale_buffers = buffer.close_stale_buffers,
  new_transaction = transaction.new,
}
