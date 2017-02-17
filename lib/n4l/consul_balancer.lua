--
--
--
--

-- Dependencies
local http = require "resty.http"
local balancer = require "ngx.balancer"
local json = require "cjson"

local WATCH_RETRY_TIMER = 0.5

local ok, new_tab = pcall(require, "table.new")
if not ok or type(new_tab) ~= "function" then
  new_tab = function (narr, nrec) return {} end
end

local _M = new_tab(0, 5) -- Change the second number.

_M.VERSION = "0.01"
_M._cache = {}

function _sanitize_uri(consul_uri)
  -- TODO: Ensure that uri has <proto>://<host>[:<port>] scheme
  return consul_uri
end

function _timer(...)
  local ok, err = ngx.timer.at(...)
  if not ok then
    ngx.log(ngx.ERR, "[FATAL] consul.balancer: failed to create timer: ", err)
  end
end

function _parse_service(service_id, response)
  if response.status ~= 200 then
    return nil, "bad response code: " .. response.status
  end
  local ok, content = pcall(function()
    return json.decode(response.body)
  end)
  if not ok then
    return nil, "JSON decode error"
  end
  if not response.headers["X-Consul-Knownleader"] or response.headers["X-Consul-Knownleader"] == "false" then
    return nil, "not trusting leaderless consul"
  end
  -- TODO: reuse some table?
  local service = {
    id = service_id
  }
  if not response.headers["X-Consul-Index"] then
    return nil, "missing consul index"
  else
    service.index = response.headers["X-Consul-Index"]
  end
  service.upstreams = {}
  for k, v in pairs(content) do
    -- if v["ServiceID"] == service_id then -- I think this check is useless
    table.insert(service.upstreams, {
        address = v["Address"],
        port = v["ServicePort"],
      })
    -- end
  end
  return service
end

function _persist(service)
  -- TODO: save to shared storage
  _M._cache[service.id] = service
end

function _aquire(service_id)
  -- TODO: get from shared storage
  return _M._cache[service_id]
end

function _refresh(service_id, hc, index)
  local uri = _M._consul_uri .. "/v1/catalog/service/" .. service_id .. "?index=" .. index .. "&wait=5m"
  ngx.log(ngx.INFO, "consul.balancer: query uri: ", uri)
  local res, err = hc:request_uri(uri, {
    method = "GET"
  })
  if res == nil then
    ngx.log(ngx.ERR, "consul.balancer: FAILED to refresh upstreams: ", err)
    return nil, err
  else
    local service, err = _parse_service(service_id, res)
    if err == nil then
      -- TODO: Save only newer data from consul to reduce GC load
      ngx.log(ngx.INFO, "consul.balancer: persisted service ", service_id, " index: ", service.index)
      _persist(service)
      return service
    else
      ngx.log(ngx.ERR, "consul.balancer: failed to parse consul response: ", err)
      return nil, err
    end
  end
end

-- signature must match nginx timer API
function _watch(premature, service_id)
  if premature then
    return nil
  end
  local hc = http:new()
  hc:set_timeout(360000) -- consul api has a default of 5 minutes for tcp long poll
  local service_index = 0
  ngx.log(ngx.NOTICE, "consul.balancer: started watching for changes in ", service_id)
  while true do
    local service, err = _refresh(service_id, hc, service_index)
    if err ~= nil then
      ngx.log(ngx.ERR, "consul.balancer: failed while watching for changes in ", service_id)
      _timer(WATCH_RETRY_TIMER, _watch, service_id)
      return nil
    end
    service_index = service.index
  end
end

function _M.watch(consul_uri, service_list)
  -- TODO: Reconsider scope for this variable.
  _M._consul_uri = _sanitize_uri(consul_uri)
  for k,v in pairs(service_list) do
    _timer(0, _watch, v)
  end
end

function _M.round_robin(service_id)
  local service = _aquire(service_id)
  if service == nil then
    ngx.log(ngx.ERR, "consul.balancer: no entry found for service: ", service_id)
    return ngx.exit(500)
  end
  if service.upstreams == nil or #service.upstreams == 0 then
    ngx.log(ngx.ERR, "consul.balancer: no peers for service: ", service_id)
  end
  if service.state == nil or service.state > #service.upstreams then
    service.state = 1
  end
  local upstream = service.upstreams[service.state]
  service.state = service.state + 1

  local ok, err = balancer.set_current_peer(upstream["address"], upstream["port"])
  if not ok then
    ngx.log(ngx.ERR, "consul.balancer: failed to set the current peer: ", err)
    return ngx.exit(500)
  end
end

return _M
