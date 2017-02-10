
local http = require "resty.http"
local setmetatable = setmetatable

local ok, new_tab = pcall(require, "table.new")
if not ok or type(new_tab) ~= "function" then
  new_tab = function (narr, nrec) return {} end
end


local _M = new_tab(0, 60) --Change the second number.

_M.VERSION = "0.01"

local mt = { __index = _M }

function _M.new(self)
  local httpc = http.new()
  return setmetatable({ _httpc = httpc }, mt)
end

