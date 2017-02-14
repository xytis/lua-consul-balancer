--
--
--
--

local http = require "resty.http"

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

function _refresh(service_id, hc)
  if hc == nil then
    hc = http:new()
  end
  local res, err = hc:request_uri(_M._consul_uri .. "/v1/catalog/service/" .. service_id, {
      method = "GET"
    })
  if res == nil then
    ngx.log(ngx.ERR, "consul.balancer: FAILED to refresh upstreams: ", err)
  else
    local service, err = _parse_service(service_id, res)
    if err == nil then
      _persist(service)
    else
      ngx.log(ngx.ERR, "consul.balancer: failed to parse consul response: ", err)
    end
  end
end

function _watch(service_id)
  local hc = http:new()
  _refresh(service_id, hc)
  local current_service, err = _aquire(service_id)
  if err ~= nil then
    ngx.log(ngx.ERR, "consul.balancer: failed to start watching for changes in ", service_id)
    _timer(WATCH_RETRY_TIMER, _watch, service_id)
    return nil, err
  end
  ngx.log(ngx.INFO, "consul.balancer: started watching for changes in ", service_id)
  while true do
    local res, err = hc:request_uri(_M._consul_uri .. "/v1/catalog/service/" .. service_id .. "?index=" .. current_service.index, {
        method = "GET"
      })
    if res ~= nil and res.body then
      local ok, data = pcall(function()
        return json.decode(res.body)
      end)
      local service = _parse_service(data)
      if service.modification_index ~= current_service.modification_index then
        _persist(service)
      end
    end
  end
end

function _M.watch(consul_uri, service_list)
  -- TODO: Reconsider scope for this variable.
  _M._consul_uri = _sanitize_uri(consul_uri)
  for k,v in pairs(service_list) do
    _timer(0, _refresh, v)
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
