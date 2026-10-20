set -e
cd /github/home
echo Install dependencies.
apt-get update > /dev/null 2>&1
apt-get install --allow-change-held-packages --allow-downgrades --allow-remove-essential \
-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -fy \
cmake git libmaxminddb-dev patch wget > /dev/null 2>&1
wget -qO /etc/apt/trusted.gpg.d/nginx_signing.asc https://nginx.org/keys/nginx_signing.key
echo deb-src https://nginx.org/packages/debian trixie nginx \
>> /etc/apt/sources.list
echo -e 'Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900' \
> /etc/apt/preferences.d/99nginx
apt-get update > /dev/null 2>&1
apt-get build-dep --allow-change-held-packages --allow-downgrades --allow-remove-essential \
-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -fy \
nginx > /dev/null 2>&1
echo Fetch NGINX source code.
apt-get source nginx > /dev/null 2>&1
cd nginx-*
NGINX_VERSION=$(dpkg-parsechangelog -S Version)
NGINX_VERSION=${NGINX_VERSION%%-*}
NGINX_MINOR=${NGINX_VERSION%.*}
mkdir debian/modules
cd debian/modules
echo Fetch fingerprint module source code.
git clone --depth 1 https://github.com/phuslu/nginx-ssl-fingerprint > /dev/null 2>&1
echo Fetch additional dependencies.
git clone --depth 1 --recursive https://github.com/google/ngx_brotli > /dev/null 2>&1
mkdir ngx_brotli/deps/brotli/out
cd ngx_brotli/deps/brotli/out
cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_INSTALL_PREFIX=installed .. \
> /dev/null 2>&1
cmake --build . --config Release --target brotlienc > /dev/null 2>&1
cd ../../../..
git clone --depth 1 --recursive https://github.com/leev/ngx_http_geoip2_module > /dev/null 2>&1
git clone --depth 1 --recursive https://github.com/openresty/headers-more-nginx-module > /dev/null 2>&1
echo Select fingerprint patches.
FP_MODULE=nginx-ssl-fingerprint
FP_TIER=3
FP_PATCH=
FP_NOTE='no applicable patch; JA3/JA4 fingerprinting omitted'
SSL_TAG=
if [ -f /github/workspace/.nofp ]; then
  FP_NOTE='forced no-fingerprint build via .nofp marker'
else
  CAND="$FP_MODULE/patches/release-$NGINX_VERSION.patch"
  if [ -f "$CAND" ] && patch -p1 --fuzz=3 --dry-run -d ../.. < "$CAND" > /dev/null 2>&1; then
    FP_PATCH=$CAND
    FP_TIER=1
    FP_NOTE="fingerprint patch release-$NGINX_VERSION applied exactly"
  else
    CAND=$(cd "$FP_MODULE/patches" && find . -maxdepth 1 -name "release-$NGINX_MINOR.*.patch" -printf '%f\n' \
    | sort -V | tail -n1)
    if [ -n "$CAND" ] && patch -p1 --fuzz=3 --dry-run -d ../.. < "$FP_MODULE/patches/$CAND" > /dev/null 2>&1; then
      FP_PATCH="$FP_MODULE/patches/$CAND"
      FP_TIER=2
      FP_NOTE="WARNING: fingerprint patch fuzzed from ${CAND%.patch} onto nginx $NGINX_VERSION"
    fi
  fi
  if [ -n "$FP_PATCH" ]; then
    SSL_TAG=$(cd "$FP_MODULE/patches" && find . -maxdepth 1 -name 'openssl-3.5.*.patch' -printf '%f\n' \
    | sed 's/^openssl-\(.*\)\.patch$/\1/' | sort -V | tail -n1)
    if [ -n "$SSL_TAG" ]; then
      echo Fetch OpenSSL $SSL_TAG source code.
      git clone --depth 1 -b openssl-$SSL_TAG https://github.com/openssl/openssl > /dev/null 2>&1
      if patch -p1 --fuzz=3 --dry-run -d openssl < "$FP_MODULE/patches/openssl-$SSL_TAG.patch" > /dev/null 2>&1; then
        patch -p1 --fuzz=3 -d openssl < "$FP_MODULE/patches/openssl-$SSL_TAG.patch" > /dev/null 2>&1
      else
        SSL_TAG=
      fi
    fi
    if [ -z "$SSL_TAG" ]; then
      FP_PATCH=
      FP_TIER=3
      FP_NOTE='no applicable OpenSSL 3.5.x patch; JA3/JA4 fingerprinting omitted'
      rm -rf openssl
    else
      patch -p1 --fuzz=3 -d ../.. < "$FP_PATCH" > /dev/null 2>&1
    fi
  fi
fi
FP_STATE=
if [ -z "$FP_PATCH" ]; then
  FP_STATE=-nofp
fi
echo Fingerprint tier: $FP_TIER - $FP_NOTE
echo Build nginx.
cd ..
sed -i 's|NGINX Packaging <nginx-packaging@f5.com>|USERNAME <USERNAME@users.noreply.github.com>|g' control
sed -i 's|export DEB_CFLAGS_MAINT_APPEND=.*|export DEB_CFLAGS_MAINT_APPEND=|g' rules
sed -i 's|export DEB_LDFLAGS_MAINT_APPEND=.*|export DEB_LDFLAGS_MAINT_APPEND=|g' rules
sed -i 's|CFLAGS=""|CFLAGS="-Wno-error"|g' rules
sed -i 's|--sbin-path=/usr/sbin/nginx|--sbin-path=/usr/sbin/nginx --add-module=$(CURDIR)/debian/modules/ngx_brotli --add-module=$(CURDIR)/debian/modules/ngx_http_geoip2_module --add-module=$(CURDIR)/debian/modules/headers-more-nginx-module|g' rules
sed -i 's|--http-scgi-temp-path=/var/cache/nginx/scgi_temp --user=nginx --group=nginx|--user=www-data --group=www-data|g' rules
sed -i 's|--with-compat||g' rules
sed -i 's|--with-mail --with-mail_ssl_module --with-stream --with-stream_realip_module --with-stream_ssl_module --with-stream_ssl_preread_module|--with-pcre-jit --without-select_module --without-poll_module --without-http_autoindex_module --without-http_browser_module --without-http_charset_module --without-http_empty_gif_module --without-http_memcached_module --without-http_mirror_module --without-http_referer_module --without-http_split_clients_module --without-http_scgi_module --without-http_ssi_module|g' rules
if [ -n "$FP_PATCH" ]; then
  sed -i 's|--with-http_ssl_module|--with-http_ssl_module --with-openssl=$(CURDIR)/debian/modules/openssl --add-module=$(CURDIR)/debian/modules/nginx-ssl-fingerprint|g' rules
fi
grep -q -- '--with-http_v2_module' rules
grep -q -- '--with-http_v3_module' rules
grep -q -- '--with-http_auth_request_module' rules
grep -q -- '--with-http_realip_module' rules
grep -q -- '--with-http_stub_status_module' rules
grep -q -- '--add-module=$(CURDIR)/debian/modules/ngx_brotli' rules
if grep -q -- '--with-stream' rules || grep -q -- '--with-mail' rules; then
  echo 'upstream rules layout changed: stream/mail-strip sed did not match' >&2
  exit 1
fi
if [ -n "$FP_PATCH" ]; then
  grep -q -- '--with-openssl=$(CURDIR)/debian/modules/openssl' rules
  grep -q -- '--add-module=$(CURDIR)/debian/modules/nginx-ssl-fingerprint' rules
else
  if grep -q 'debian/modules/openssl' rules || grep -q 'nginx-ssl-fingerprint' rules; then
    echo 'fingerprint flags present in a no-fingerprint build' >&2
    exit 1
  fi
fi
cd ..
dpkg-buildpackage -b > /dev/null 2>&1
cd ..
cp nginx_*.deb nginx.deb
hash=$(sha256sum nginx.deb | awk '{print $1}')
change=
if [[ $hash != $(cat /github/workspace/hash) ]]; then
  echo $hash > /github/workspace/hash
  echo $NGINX_VERSION$FP_STATE > /github/workspace/nginx-version
  change=1
  echo This is a new version.
else
  echo This is an old version.
fi
{
  echo "hash=$hash"
  echo "nginx_version=$NGINX_VERSION"
  echo "fp_state=$FP_STATE"
  echo "fp_tier=$FP_TIER"
  echo "change=$change"
} >> $GITHUB_ENV
{
  echo "release_note<<NOTE_EOF"
  echo "nginx $NGINX_VERSION (stable branch) with HTTP/3/QUIC and JA3/JA4 fingerprinting."
  echo ""
  echo "- Artifact SHA256: $hash"
  echo "- Fingerprint tier: $FP_TIER - $FP_NOTE"
  if [ -n "$SSL_TAG" ]; then
    echo "- OpenSSL: $SSL_TAG (patched for client-hello capture)"
  else
    echo "- OpenSSL: system libssl (fingerprint module omitted)"
  fi
  echo "NOTE_EOF"
} >> $GITHUB_ENV
