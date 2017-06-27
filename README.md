# lua-consul-balancer

[![Build Status](https://travis-ci.org/xytis/lua-consul-balancer.svg?branch=master)](https://travis-ci.org/xytis/lua-consul-balancer)

Consul enabled upstream balancer. Does exactly what is advertised -- enables nginx to use consul service discovery to forward requests to dynamic upstreams.

## Usage

Each nginx worker must initialize the library:

    lua_shared_dict consul_balancer 16k;

    init_worker_by_lua_block {
      local consul_balancer = require "n4l.consul_balancer"
      consul_balancer.set_shared_dict_name("consul_balancer") # name of shared dictionary to keep cache in
      consul_balancer.watch("http://127.0.0.1:8500", {"foo", "bar"})
    }

You may define extended attributes in service descriptor:

    consul_balancer.watch("http://127.0.0.1:8500", {
      "foo",                -- short form
      {
        name="bar",         -- mandatory field
        service="foo-bar",  -- defaults to 'name'
        tag="http",
        near="_agent",
        dc="dc2",
        ["node-meta"]="key:value"
      }
    })

Attribute explanation is listed in [consul docs](https://www.consul.io/docs/agent/http/catalog.html#catalog_service).

Once the worker is initialised, you can define upstream like this:

    upstream upstream_foo {
      server 127.0.0.1:666; # Required, because empty upstream block is rejected by nginx (nginx+ can use 'zone' instead)
      balancer_by_lua_block {
        local consul_balancer = require "n4l.consul_balancer"
        consul_balancer.round_robin("foo")
      }
    }

Upstream usage is normal and follows all expected nginx rules:

    location /somefoo {
      proxy_pass http://upstream_foo;
    }

## Known issues

Due to limitation of 'init_worker_by_lua_*' to [run lua cosockets](https://github.com/openresty/lua-nginx-module#cosockets-not-available-everywhere)
initial lookup is done async from the startup sequence. That leaves a delay, measurable in roundtrip time from consul to nginx, until lua balancer has upstreams to forward requests to.
