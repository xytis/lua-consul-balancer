export JOBS=3
export NGX_BUILD_JOBS=$JOBS
export LUAJIT_PREFIX=/opt/luajit21
export LUAJIT_LIB=$LUAJIT_PREFIX/lib
export LUAJIT_INC=$LUAJIT_PREFIX/include/luajit-2.1
export LUA_INCLUDE_DIR=$LUAJIT_INC
export OPENSSL_PREFIX=/opt/ssl
export OPENSSL_LIB=$OPENSSL_PREFIX/lib
export OPENSSL_INC=$OPENSSL_PREFIX/include
export OPENSSL_VER=1.0.2h
export CONSUL_VER=0.7.4
export LD_LIBRARY_PATH=$LUAJIT_LIB:$LD_LIBRARY_PATH
export TEST_NGINX_SLEEP=0.006
export NGINX_VERSION=1.9.15

set -e

if [ ! -d download-cache ]; then mkdir download-cache; fi
if [ ! -f download-cache/openssl-$OPENSSL_VER.tar.gz ]; then wget -O download-cache/openssl-$OPENSSL_VER.tar.gz https://www.openssl.org/source/openssl-$OPENSSL_VER.tar.gz; fi
if [ ! -f download-cache/consul_${CONSUL_VER}_linux_amd64.zip ]; then wget -O download-cache/consul_${CONSUL_VER}_linux_amd64.zip https://releases.hashicorp.com/consul/${CONSUL_VER}/consul_${CONSUL_VER}_linux_amd64.zip; fi
sudo apt-get install -qq -y cpanminus axel unzip
sudo apt-get build-dep -qq -y nginx

sudo cpanm --notest Test::Nginx > build.log 2>&1 || (cat build.log && exit 1)
wget http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz
git clone https://github.com/openresty/openresty.git ../openresty
git clone https://github.com/openresty/nginx-devel-utils.git
git clone https://github.com/openresty/lua-cjson.git
git clone https://github.com/openresty/lua-resty-core.git
git clone https://github.com/pintsized/lua-resty-http.git
git clone https://github.com/openresty/lua-nginx-module.git ../lua-nginx-module
git clone https://github.com/openresty/echo-nginx-module.git ../echo-nginx-module
git clone https://github.com/openresty/no-pool-nginx.git ../no-pool-nginx
git clone -b v2.1-agentzh https://github.com/openresty/luajit2.git

# LUAJIT
cd luajit2/
make -j$JOBS CCDEBUG=-g Q= PREFIX=$LUAJIT_PREFIX CC=$CC XCFLAGS='-DLUA_USE_APICHECK -DLUA_USE_ASSERT' > build.log 2>&1 || (cat build.log && exit 1)
sudo make install PREFIX=$LUAJIT_PREFIX > build.log 2>&1 || (cat build.log && exit 1)
cd -
# LUA DEPS
cd lua-cjson && make && sudo PATH=$PATH make install && cd -
cd lua-resty-http && make && sudo PATH=$PATH make install && cd -
cd lua-resty-core && make && sudo PATH=$PATH make install && cd -
# OPENSSL
tar zxf download-cache/openssl-$OPENSSL_VER.tar.gz
cd openssl-$OPENSSL_VER/
./config shared --prefix=$OPENSSL_PREFIX -DPURIFY > build.log 2>&1 || (cat build.log && exit 1)
make -j$JOBS > build.log 2>&1 || (cat build.log && exit 1)
sudo make PATH=$PATH install_sw > build.log 2>&1 || (cat build.log && exit 1)
cd -
# CONSUL
unzip download-cache/consul_${CONSUL_VER}_linux_amd64.zip
./consul agent -dev > consul.out 2>&1 &
# NGINX
export PATH=$PWD/work/nginx/sbin:$PWD/nginx-devel-utils:$PATH
export NGX_BUILD_CC=$CC
ngx-build $NGINX_VERSION --with-ipv6 --with-http_realip_module --with-http_ssl_module --add-module=../echo-nginx-module --add-module=../lua-nginx-module --with-debug > build.log 2>&1 || (cat build.log && exit 1)
nginx -V
ldd `which nginx`|grep -E 'luajit|ssl|pcre'

# RUNTIME
while true; do echo -ne "HTTP/1.0 200 OK\r\n\r\nfoo-1:8667\r\n" | nc -l -p 8667 > access.log; done &
curl -X PUT -d '{"ID": "foo-1", "Name": "foo", "Port": 8667 }' http://127.0.0.1:8500/v1/agent/service/register

while true; do echo -ne "HTTP/1.0 200 OK\r\n\r\nfoo-2:8668\r\n" | nc -l -p 8668 >> access.log; done &
curl -X PUT -d '{"ID": "foo-2", "Name": "foo", "Port": 8668 }' http://127.0.0.1:8500/v1/agent/service/register

while true; do echo -ne "HTTP/1.0 200 OK\r\n\r\nfoo-3:8669\r\n" | nc -l -p 8669 >> access.log; done &
curl -X PUT -d '{"ID": "foo-3", "Name": "foo", "Port": 8669 }' http://127.0.0.1:8500/v1/agent/service/register

curl -s http://127.0.0.1:8500/v1/catalog/service/foo?pretty | grep ServiceID

while true; do echo -ne "HTTP/1.0 200 OK\r\n\r\nbar-1:8665\r\n" | nc -l -p 8665 >> access.log; done &
curl -X PUT -d '{"ID": "bar-1", "Name": "bar", "Port": 8665 }' http://127.0.0.1:8500/v1/agent/service/register

curl -s http://127.0.0.1:8500/v1/catalog/service/bar?pretty | grep ServiceID

curl -X PUT -d '{"ID": "poo-dead", "Name": "poo", "Port": 666, "Check": {"HTTP": "http://127.0.0.1:666/health", "Interval": "10s"}}' http://127.0.0.1:8500/v1/agent/service/register
curl -s http://127.0.0.1:8500/v1/catalog/service/poo?pretty | grep ServiceID

prove -r t
