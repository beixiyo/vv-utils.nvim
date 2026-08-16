-- vv-utils HTTP 公共入口：非流式安全 curl transport 与查询参数工具

local Curl = require('vv-utils.http.curl')
local Query = require('vv-utils.http.query')

---@class vv-utils.http.RequestOptions
---@field url string 请求地址
---@field method? string HTTP 方法，默认 GET
---@field headers? table<string, string>|string[] 请求头映射，或完整请求头行列表
---@field body? string 请求体
---@field timeout_ms? number 超时时间（毫秒），默认 15000

---@class vv-utils.http.Response
---@field status integer HTTP 状态码
---@field body string 响应体
---@field headers table<string, string> 小写请求头名称到值的映射

---@class vv-utils.http.Error
---@field code string 稳定的错误代码
---@field message string 可直接展示给用户的英文错误
---@field cause? any 底层错误，仅包含非敏感诊断信息

return {
  request = Curl.request,
  encode_query_component = Query.encode_query_component,
  append_query = Query.append_query,
}
