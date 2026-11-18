set -e
cd /github/home
# A fallback run (NGX_FP_FORCE_NOFP=1) reuses /github/home after a failed fingerprinted build.
rm -rf nginx-[0-9]* nginx_* nginx.deb nginx-dbg.deb
NOFP_REASON=
if [ -f /github/workspace/.nofp ]; then
  NOFP_REASON='forced no-fingerprint build via .nofp marker'
elif [ -n "${NGX_FP_FORCE_NOFP:-}" ]; then
  NOFP_REASON='the fingerprinted build of this new nginx version failed (see the failed Build step), so this fallback build omits the fingerprint module'
fi
echo Install dependencies.
apt-get update > /dev/null 2>&1
apt-get install --allow-change-held-packages --allow-downgrades --allow-remove-essential \
-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -fy \
cmake git libmaxminddb-dev libzstd-dev patch wget zlib1g-dev > /dev/null 2>&1
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
if [ -n "${NGX_FP_FORCE_NOFP:-}" ]; then
  # Fall back to -nofp only to ship a NEW nginx version on time; never trade a working
  # fingerprinted release of the same version for a -nofp one.
  LAST_VERSION=$(cat /github/workspace/nginx-version 2>/dev/null || true)
  if [ "$NGINX_VERSION" = "${LAST_VERSION%-nofp}" ]; then
    echo "::error title=Fingerprinted build failed::nginx $NGINX_VERSION is already released (v$LAST_VERSION), so no -nofp fallback is published and servers keep their current build. See the failed Build step."
    exit 1
  fi
  echo "New nginx $NGINX_VERSION (last released: ${LAST_VERSION:-none}): publishing a -nofp fallback."
fi
mkdir debian/modules
cd debian/modules
# nginx-ssl-fingerprint is pinned: JA4 rules match the exact values this commit produces.
# Upstream changed the values on 2026-11-11 (extensions captured from the raw ClientHello,
# signature algorithms in wire order, sorted JA3 extensions): browser JA4 part a and part c
# both shift (Edge 157 t13d1514h2_..._ee79ac1fafef -> t13d1516h2_..._806a8c22fdea).
# Move the pin only together with a migration of every rule that matches JA4 values.
FP_COMMIT=e72f932b630717939b508b58e5b4a48ec014adf3
if [ -z "$NOFP_REASON" ]; then
  echo Fetch fingerprint module source code, commit $FP_COMMIT.
  if ! git clone https://github.com/phuslu/nginx-ssl-fingerprint > /dev/null 2>&1 \
  || ! git -C nginx-ssl-fingerprint checkout -q "$FP_COMMIT" > /dev/null 2>&1; then
    echo "::error title=fingerprint module pin::cannot check out nginx-ssl-fingerprint commit $FP_COMMIT. Until fixed the current release stays (a new nginx version ships without fingerprinting)."
    exit 1
  fi
  echo Apply fix for nginx-ssl-fingerprint issue 87.
  FIX87=/github/workspace/patches/fp-87-quic-pool.patch
  FP_SRC=nginx-ssl-fingerprint/src/nginx_ssl_fingerprint.c
  if ! patch -p1 --fuzz=0 --dry-run -d nginx-ssl-fingerprint < "$FIX87" > /dev/null 2>&1; then
    echo "::error title=fp-87 patch no longer applies::patches/fp-87-quic-pool.patch does not apply to nginx-ssl-fingerprint $FP_COMMIT (was FP_COMMIT moved?). Upstream fixed issue 87 itself on 2026-11-11 (ngx_ssl_fp_pool, PR 94): a pin at or after that commit needs neither this patch nor this block. Until fixed the current release stays (a new nginx version ships without fingerprinting)."
    exit 1
  fi
  patch -p1 --fuzz=0 -d nginx-ssl-fingerprint < "$FIX87" > /dev/null 2>&1
  if grep -q 'ngx_pnalloc(c->pool, c->ssl->fp_' "$FP_SRC" \
  || [ "$(grep -c 'ngx_ssl_fp_pnalloc(c, c->ssl->fp_' "$FP_SRC")" != 3 ]; then
    echo '::error title=fp-87 patch incomplete::cached c->ssl strings are still allocated from c->pool'
    exit 1
  fi
fi
echo Fetch additional dependencies.
git clone --depth 1 --recursive https://github.com/google/ngx_brotli > /dev/null 2>&1
mkdir ngx_brotli/deps/brotli/out
cd ngx_brotli/deps/brotli/out
cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_INSTALL_PREFIX=installed .. \
> /dev/null 2>&1
cmake --build . --config Release --target brotlienc brotlidec > /dev/null 2>&1
cd ../../../..
git clone --depth 1 --recursive https://github.com/leev/ngx_http_geoip2_module > /dev/null 2>&1
git clone --depth 1 --recursive https://github.com/openresty/headers-more-nginx-module > /dev/null 2>&1
echo Select fingerprint patches.
FP_MODULE=nginx-ssl-fingerprint
FP_TIER=3
FP_PATCH=
FP_NOTE='no applicable patch; JA3/JA4 fingerprinting omitted'
SSL_TAG=
if [ -n "$NOFP_REASON" ]; then
  FP_NOTE=$NOFP_REASON
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
    SSL_PATCH_TAG=$(cd "$FP_MODULE/patches" && find . -maxdepth 1 -name 'openssl-3.5.*.patch' -printf '%f\n' \
    | sed 's/^openssl-\(.*\)\.patch$/\1/' | sort -V | tail -n1)
    SSL_TAG=
    if [ -n "$SSL_PATCH_TAG" ]; then
      SSL_LATEST=$(git ls-remote --tags --refs https://github.com/openssl/openssl 'openssl-3.5.*' \
      | sed -n 's|.*refs/tags/openssl-\(3\.5\.[0-9]*\)$|\1|p' | sort -V | tail -n1)
      for CAND in $(printf '%s\n' "$SSL_LATEST" "$SSL_PATCH_TAG" | awk 'NF && !seen[$0]++'); do
        FUZZ=0
        if [ "$CAND" = "$SSL_PATCH_TAG" ]; then
          FUZZ=3
        fi
        echo Fetch OpenSSL $CAND source code.
        rm -rf openssl
        git clone --depth 1 -b openssl-$CAND https://github.com/openssl/openssl > /dev/null 2>&1 || continue
        if patch -p1 --fuzz=$FUZZ --dry-run -d openssl < "$FP_MODULE/patches/openssl-$SSL_PATCH_TAG.patch" > /dev/null 2>&1; then
          patch -p1 --fuzz=$FUZZ -d openssl < "$FP_MODULE/patches/openssl-$SSL_PATCH_TAG.patch" > /dev/null 2>&1
          SSL_TAG=$CAND
          break
        fi
      done
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
  sed -i 's|--with-http_ssl_module|--with-http_ssl_module --with-openssl=$(CURDIR)/debian/modules/openssl --with-openssl-opt="zlib enable-brotli enable-zstd --with-brotli-include=$(CURDIR)/debian/modules/ngx_brotli/deps/brotli/c/include --with-brotli-lib=$(CURDIR)/debian/modules/ngx_brotli/deps/brotli/out" --add-module=$(CURDIR)/debian/modules/nginx-ssl-fingerprint|g' rules
  sed -i 's|^\( *\)CORE_LIBS="$CORE_LIBS $OPENSSL/.openssl/lib/libcrypto.a"$|&\n\1CORE_LIBS="$CORE_LIBS -lbrotlienc -lbrotlidec -lbrotlicommon -lzstd -lz"|' ../auto/lib/openssl/conf
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
  grep -q -- '--with-openssl-opt="zlib enable-brotli enable-zstd' rules
  grep -q -- '-lbrotlienc -lbrotlidec -lbrotlicommon -lzstd -lz' ../auto/lib/openssl/conf
  test -f modules/ngx_brotli/deps/brotli/out/libbrotlidec.a
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
cp nginx-dbg_*.deb nginx-dbg.deb
hash=$(sha256sum nginx.deb | awk '{print $1}')
change=
RELEASE=
RELEASE_TITLE=
if [[ $hash != $(cat /github/workspace/hash) ]]; then
  # Release numbers are this repo's own (like nginx-http3): a push to main (a change to the
  # build) bumps minor, any other run with a new .deb (new nginx point release, new OpenSSL,
  # module updates) bumps patch. The first release is 1.0.0. nginx-version keeps the nginx
  # version for the -nofp fallback rule above.
  LAST_RELEASE=$(cat /github/workspace/release-version 2>/dev/null || true)
  if [ -z "$LAST_RELEASE" ]; then
    RELEASE=1.0.0
  elif [[ $LAST_RELEASE =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    if [ "${GITHUB_EVENT_NAME:-}" = push ]; then
      RELEASE=${BASH_REMATCH[1]}.$((BASH_REMATCH[2] + 1)).0
    else
      RELEASE=${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1))
    fi
  else
    echo "::error title=release-version::release-version contains '$LAST_RELEASE', expected X.Y.Z"
    exit 1
  fi
  RELEASE_TITLE="v$RELEASE (nginx $NGINX_VERSION)"
  if [ -n "$FP_STATE" ]; then
    RELEASE_TITLE="v$RELEASE (nginx $NGINX_VERSION, no fingerprinting)"
  fi
  echo $hash > /github/workspace/hash
  echo $NGINX_VERSION$FP_STATE > /github/workspace/nginx-version
  echo $RELEASE > /github/workspace/release-version
  change=1
  echo "This is a new version: v$RELEASE."
else
  echo This is an old version.
fi
{
  echo "hash=$hash"
  echo "nginx_version=$NGINX_VERSION"
  echo "fp_state=$FP_STATE"
  echo "fp_tier=$FP_TIER"
  echo "fp_note=$FP_NOTE"
  echo "change=$change"
  echo "release_version=$RELEASE"
  echo "release_title=$RELEASE_TITLE"
} >> $GITHUB_ENV
{
  echo "release_note<<NOTE_EOF"
  if [ -n "$FP_STATE" ]; then
    echo "nginx $NGINX_VERSION (stable branch) with HTTP/3/QUIC, built WITHOUT JA3/JA4 fingerprinting."
  else
    echo "nginx $NGINX_VERSION (stable branch) with HTTP/3/QUIC and JA3/JA4 fingerprinting."
  fi
  echo ""
  echo "- Artifact SHA256: $hash"
  echo "- Fingerprint tier: $FP_TIER - $FP_NOTE"
  if [ -n "$SSL_TAG" ]; then
    echo "- OpenSSL: $SSL_TAG (patched for client-hello capture with openssl-$SSL_PATCH_TAG.patch; zlib/brotli/zstd certificate compression)"
    echo "- nginx-ssl-fingerprint: pinned at ${FP_COMMIT:0:7}, plus local fix for issue 87 (HTTP/3 dangling pointer)"
  else
    echo "- OpenSSL: system libssl (fingerprint module omitted)"
  fi
  echo "NOTE_EOF"
} >> $GITHUB_ENV
