--
--
--
--
local next = next

-- Dependencies
local http = require "resty.http"
local balancer = require "ngx.balancer"
local json = require "cjson"
local resty_roundrobin = require "resty.roundrobin"

local WATCH_RETRY_TIMER = 0.5

local ok, new_tab = pcall(require, "table.new")
if not ok or type(new_tab) ~= "function" then
  new_tab = function (narr, nrec) return {} end
end

local _M = new_tab(0, 5) -- Change the second number.

_M.VERSION = "0.04"
_M._cache = {} -- To save the "service" object

local function _sanitize_uri(consul_uri)
  -- TODO: Ensure that uri has <proto>://<host>[:<port>] scheme
  return consul_uri
end

local function _timer(...)
  local ok, err = ngx.timer.at(...)
  if not ok then
    ngx.log(ngx.ERR, "[FATAL] consul.balancer: failed to create timer: ", err)
  end
end

local function _parse_service(response)
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
  local service = {}
  if not response.headers["X-Consul-Index"] then
    return nil, "missing consul index"
  else
    service.index = response.headers["X-Consul-Index"]
  end
  service.upstreams = {}
  for k, v in pairs(content) do
    local passing = true
    local checks = v["Checks"]
    for i, c in pairs(checks) do
      if c["Status"] ~= "passing" then
        passing = false
      end
    end
    if passing then
      local s = v["Service"]
      local na = v["Node"]["Address"]
      local address = s["Address"] ~= "" and s["Address"] or na
      local port = s["Port"]
      -- If the weight parameter fails to be obtained or is passed incorrectly, set it to 1
      local weight = s["Weights"]["Passing"] or 1
      if type(weight) == "number" and weight > 0 then
        service.upstreams[address .. ":" .. port] = weight
        ngx.log(ngx.INFO, "consul.balancer: add " .. address .. ":" .. port .. " to upstreams, weight " .. weight)
      else
        ngx.log(ngx.ALERT, "consul.balancer: upstream " .. address .. ":" .. port .. " weight set error:" .. weight)
      end
    end
  end
  if service.upstreams ==nil or next(service.upstreams) ==nil then
    ngx.log(ngx.ERR, "[FATAL] consul.balancer: upstream list is nil")
    return nil, "upstream list is nil"
  end
  local rr_up = resty_roundrobin:new(service.upstreams)
  service.rr_up = rr_up
  return service
end

local function _persist(service_name, service)
  -- Shared cache requires encode & decode to store data. The "find" method of rr_up objects will be lost. 
  -- Therefore, the rr_up objects are stored directly using table.
  _M._cache[service_name] = service
end

local function _aquire(service_name)
  -- When using table to store an rr_up object, simply return it
  return _M._cache[service_name]
end

local function _build_service_uri(service_descriptor, service_index)
  local uri = _M._consul_uri .. "/v1/health/service/" .. service_descriptor.service
  local args = {
    index = service_index,
    wait = "5m"
  }
  if service_descriptor.dc ~= nil then
    args.dc = service_descriptor.dc
  end
  if service_descriptor.tag ~= nil then
    args.tag = service_descriptor.tag
  end
  if service_descriptor.near ~= nil then
    args.near = service_descriptor.near
  end
  if service_descriptor["node-meta"] ~= nil then
    args["node-meta"] = service_descriptor["node-meta"]
  end
  if service_descriptor.token ~= nil then
    args.token = service_descriptor.token
  end
  return uri .. "?" .. ngx.encode_args(args)
end

local function _refresh(hc, uri)
  ngx.log(ngx.INFO, "consul.balancer: query uri: ", uri)
  local res, err = hc:request_uri(uri, {
    method = "GET"
  })
  if res == nil then
    ngx.log(ngx.ERR, "consul.balancer: failed to refresh upstreams: ", err)
    return nil, err
  end
  local service, err = _parse_service(res)
  if err ~= nil then
    ngx.log(ngx.ERR, "consul.balancer: failed to parse consul response: ", err)
    return nil, err
  end
  return service
end

local function _validate_service_descriptor(service_descriptor)
  if type(service_descriptor) == "string" then
    service_descriptor = {
      name = service_descriptor,
      service = service_descriptor,
      tag = nil
    }
  elseif type(service_descriptor) == "table" then
    if service_descriptor.name == nil then
      return nil, "missing name field in service_descriptor"
    end
    if service_descriptor.service == nil then
      service_descriptor.service = service_descriptor.name
    end
  end
  return service_descriptor
end

-- signature must match nginx timer API
local function _watch(premature, service_descriptor)
  if premature then
    return nil
  end
  service_descriptor, err = _validate_service_descriptor(service_descriptor)
  if err ~= nil then
    ngx.log(ngx.ERR, "consul.balancer: ", err)
    return nil
  end
  local hc = http:new()
  hc:set_timeout(360000) -- consul api has a default of 5 minutes for tcp long poll
  local service_index = 0
  ngx.log(ngx.NOTICE, "consul.balancer: started watching for changes in ", service_descriptor.name)
  while not ngx.worker.exiting() do
    local uri = _build_service_uri(service_descriptor, service_index)
    local service, err = _refresh(hc, uri)
    if service == nil then
      ngx.log(ngx.ERR, "consul.balancer: failed while watching for changes in ", service_descriptor.name, " retry scheduled")
      _timer(WATCH_RETRY_TIMER, _watch, service_descriptor)
      return nil
    end
    -- TODO: Save only newer data from consul to reduce GC load
    service_index = service.index
    _persist(service_descriptor.name, service)
    ngx.log(ngx.INFO, "consul.balancer: persisted service ", service_descriptor.name,
                      " index: ", service_index, " content: ", json.encode(service))
  end
end

function _M.watch(consul_uri, service_list)
  -- Each worker process is independent and independently watches consul upstream changes
  -- TODO: Reconsider scope for this variable.
  _M._consul_uri = _sanitize_uri(consul_uri)
  for k,v in pairs(service_list) do
    _timer(0, _watch, v)
  end
end

function _M.round_robin(service_name)
  local service = _aquire(service_name)
  if service == nil then
    ngx.log(ngx.ERR, "consul.balancer: no entry found for service: ", service_name)
    return ngx.exit(500)
  end
  local rr_up = service.rr_up
  if rr_up == nil then
    ngx.log(ngx.ERR, "consul.balancer: no roundrobin object for service: ", service_name)
    return ngx.exit(500)
  end
  local server = rr_up:find()
  local ok, err = balancer.set_current_peer(server)
  if not ok then
    ngx.log(ngx.ERR, "consul.balancer: failed to set the current peer: ", err)
    return ngx.exit(500)
  end
end

return _M
