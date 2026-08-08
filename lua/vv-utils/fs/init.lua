-- 文件系统公共入口

local buffer = require('vv-utils.fs.buffer')
local dir_info = require('vv-utils.fs.dir_info')
local file_info = require('vv-utils.fs.file_info')
local file_info_highlight = require('vv-utils.fs.file_info_highlight')
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

  inspect_file = file_info.inspect,
  is_binary = file_info.is_binary,
  file_info_lines = file_info.lines,
  format_size = file_info.format_size,
  highlight_file_info = file_info_highlight.apply,

  inspect_dir = dir_info.shallow,
  scan_dir = dir_info.scan,
  dir_info_lines = dir_info.lines,

  sync_buffers = buffer.sync_buffers,
  new_transaction = transaction.new,
}
