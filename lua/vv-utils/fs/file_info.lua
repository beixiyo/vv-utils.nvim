-- 文件内容探测与元信息：小块读取识别二进制，不依赖平台外部命令

local uv = vim.uv or vim.loop

local M = {}

local DEFAULT_SAMPLE_SIZE = 8192

---@class VVFsInspectFileOptions
---@field extensions? table<string, boolean> 扩展名覆盖；显式 false 优先于内容探测
---@field sample_size? integer 读取文件头的最大字节数 @default 8192

---@class VVFsFileInfo
---@field path string
---@field exists boolean
---@field readable boolean
---@field binary boolean
---@field kind string
---@field architecture? string
---@field size? integer
---@field modified? integer
---@field executable boolean

local function u16_le(data, offset)
  local a, b = data:byte(offset, offset + 1)
  if not a or not b then return nil end
  return a + b * 256
end

local function u16_be(data, offset)
  local a, b = data:byte(offset, offset + 1)
  if not a or not b then return nil end
  return a * 256 + b
end

local function u32_le(data, offset)
  local a, b, c, d = data:byte(offset, offset + 3)
  if not a or not b or not c or not d then return nil end
  return a + b * 256 + c * 65536 + d * 16777216
end

local function u32_be(data, offset)
  local a, b, c, d = data:byte(offset, offset + 3)
  if not a or not b or not c or not d then return nil end
  return a * 16777216 + b * 65536 + c * 256 + d
end

local ARCHITECTURES = {
  [7] = 'x86',
  [12] = 'arm',
  [16777223] = 'x86_64',
  [16777228] = 'arm64',
}

local MACHO_FILE_TYPES = {
  [2] = 'executable',
  [6] = 'dynamic library',
  [8] = 'bundle',
}

---@param sample string
---@return string kind
---@return string? architecture
---@return boolean known_binary
local function detect_kind(sample)
  local magic = sample:sub(1, 4)

  local macho_bits, macho_endian
  if magic == '\207\250\237\254' then
    macho_bits, macho_endian = 64, 'le'
  elseif magic == '\254\237\250\207' then
    macho_bits, macho_endian = 64, 'be'
  elseif magic == '\206\250\237\254' then
    macho_bits, macho_endian = 32, 'le'
  elseif magic == '\254\237\250\206' then
    macho_bits, macho_endian = 32, 'be'
  end

  if macho_bits then
    local read_u32 = macho_endian == 'le' and u32_le or u32_be
    local architecture = ARCHITECTURES[read_u32(sample, 5)]
    local file_type = MACHO_FILE_TYPES[read_u32(sample, 13)] or 'binary'
    return ('Mach-O %d-bit %s'):format(macho_bits, file_type), architecture, true
  end

  if magic == '\202\254\186\190'
      or magic == '\190\186\254\202'
      or magic == '\202\254\186\191'
      or magic == '\191\186\254\202' then
    return 'Mach-O universal binary', nil, true
  end

  if magic == '\127ELF' then
    local class = sample:byte(5) == 2 and '64-bit' or sample:byte(5) == 1 and '32-bit' or ''
    local read_u16 = sample:byte(6) == 2 and u16_be or u16_le
    local machine = read_u16(sample, 19)
    local architecture = ({
      [3] = 'x86',
      [40] = 'arm',
      [62] = 'x86_64',
      [183] = 'arm64',
      [243] = 'riscv',
    })[machine]
    return vim.trim('ELF ' .. class .. ' binary'), architecture, true
  end

  if sample:sub(1, 2) == 'MZ' then return 'PE executable', nil, true end
  if magic == '\0asm' then return 'WebAssembly binary', nil, true end
  if sample:sub(1, 8) == '\137PNG\r\n\26\n' then return 'PNG image', nil, true end
  if sample:sub(1, 3) == '\255\216\255' then return 'JPEG image', nil, true end
  if sample:sub(1, 6) == 'GIF87a' or sample:sub(1, 6) == 'GIF89a' then
    return 'GIF image', nil, true
  end
  if sample:sub(1, 5) == '%PDF-' then return 'PDF document', nil, true end
  if magic == 'PK\3\4' then return 'ZIP archive', nil, true end
  if sample:sub(1, 2) == '\31\139' then return 'Gzip archive', nil, true end
  if sample:sub(1, 16) == 'SQLite format 3\0' then return 'SQLite database', nil, true end

  return sample:find('\0', 1, true) and 'Binary data' or 'Text', nil, false
end

local function read_sample(path, size)
  local fd = uv.fs_open(path, 'r', 438)
  if not fd then return nil end
  local data = uv.fs_read(fd, size, 0)
  uv.fs_close(fd)
  return data
end

local function is_executable(mode)
  if not mode then return false end
  local permissions = mode % 512
  local owner = math.floor(permissions / 64) % 8
  local group = math.floor(permissions / 8) % 8
  local other = permissions % 8
  return owner % 2 == 1 or group % 2 == 1 or other % 2 == 1
end

---@param path string
---@param opts? VVFsInspectFileOptions
---@return VVFsFileInfo
function M.inspect(path, opts)
  path = vim.fs.normalize(path)
  opts = opts or {}

  local stat = uv.fs_stat(path)
  local sample = stat and stat.type == 'file'
      and read_sample(path, math.max(1, opts.sample_size or DEFAULT_SAMPLE_SIZE))
      or nil
  local kind, architecture, known_binary = detect_kind(sample or '')

  local basename = vim.fs.basename(path)
  local ext = basename:match('%.([%w_]+)$')
  local configured
  if ext and opts.extensions then configured = opts.extensions[ext:lower()] end
  local content_binary = known_binary or (sample and sample:find('\0', 1, true) ~= nil) or false
  local modified = stat and stat.mtime
  local binary = content_binary
  if configured ~= nil then binary = configured end
  if binary and kind == 'Text' then kind = 'Binary data' end

  return {
    path = path,
    exists = stat ~= nil,
    readable = sample ~= nil,
    binary = binary,
    kind = kind,
    architecture = architecture,
    size = stat and stat.size or nil,
    modified = type(modified) == 'table' and modified.sec or modified,
    executable = stat and stat.type == 'file' and is_executable(stat.mode) or false,
  }
end

---@param path string
---@param opts? VVFsInspectFileOptions
---@return boolean
function M.is_binary(path, opts)
  return M.inspect(path, opts).binary
end

local function format_size(size)
  if size < 1024 then return size .. ' B' end
  if size < 1024 * 1024 then return ('%.1f KiB'):format(size / 1024) end
  if size < 1024 * 1024 * 1024 then return ('%.1f MiB'):format(size / 1024 / 1024) end
  return ('%.1f GiB'):format(size / 1024 / 1024 / 1024)
end

---@class VVFsFileInfoLinesOptions
---@field display_path? string
---@field title? string @default 'Binary file'

---@param info VVFsFileInfo
---@param opts? VVFsFileInfoLinesOptions
---@return string[]
function M.lines(info, opts)
  opts = opts or {}
  local lines = {
    opts.title or 'Binary file',
    '',
    'Path: ' .. (opts.display_path or info.path),
    'Type: ' .. info.kind,
  }

  if info.architecture then lines[#lines + 1] = 'Architecture: ' .. info.architecture end
  if info.size then
    lines[#lines + 1] = ('Size: %s (%d bytes)'):format(format_size(info.size), info.size)
  end
  lines[#lines + 1] = 'Executable: ' .. (info.executable and 'Yes' or 'No')
  if info.modified then
    lines[#lines + 1] = 'Modified: ' .. os.date('%Y-%m-%d %H:%M:%S', info.modified)
  end

  return lines
end

return M
