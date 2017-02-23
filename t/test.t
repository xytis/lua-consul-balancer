use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 4);

my $pwd = cwd();

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';
$ENV{TEST_COVERAGE} ||= 0;

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;/usr/local/lib/lua/?.lua;;";
    error_log logs/error.log debug;

    init_by_lua_block {
        if $ENV{TEST_COVERAGE} == 1 then
            jit.off()
            require("luacov.runner").init()
        end
    }

    init_worker_by_lua_block {
        local consul_balancer = require "n4l.consul_balancer"
        consul_balancer.watch("http://127.0.0.1:8500", {"foo", { name = "bar", service = "bar" }})
    }

    upstream upstream_foo {
        server 127.0.0.1:666;
        balancer_by_lua_block {
            local consul_balancer = require "n4l.consul_balancer"
            consul_balancer.round_robin("foo")
        }
    }

    upstream upstream_bar {
        server 127.0.0.1:666;
        balancer_by_lua_block {
            local consul_balancer = require "n4l.consul_balancer"
            consul_balancer.round_robin("bar")
        }
    }
};

no_long_string();
#no_diff();

run_tests();

__DATA__
=== TEST 1: Balancing
--- http_config eval: $::HttpConfig
--- config
    location = /foo {
        proxy_pass http://upstream_foo;
    }
    location = /bar {
        proxy_pass http://upstream_bar;
    }
--- request
GET /foo
--- response_body_like: foo-.*
--- no_error_log
[error]
[warn]

=== TEST 2: Retries
--- http_config eval: $::HttpConfig
--- config
    location = /foo {
        proxy_pass http://upstream_foo;
    }
    location = /bar {
        proxy_next_upstream error timeout invalid_header http_500 http_502 http_503 http_504 http_403 http_404;
        proxy_pass http://upstream_bar;
    }
--- request
GET /bar
--- response_body_like: bar-.*
--- error_log
(111: Connection refused)
--- no_error_log
[warn]
