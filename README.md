# nginx-fp

Debian packages of [NGINX](https://nginx.org/) (**stable branch**) with **HTTP/3/QUIC** and **TLS client fingerprinting** ([JA3](https://github.com/salesforce/ja3)/[JA4](https://github.com/FoxIO-LLC/ja4) + HTTP/2 fingerprint), auto-rebuilt by GitHub Actions on every stable nginx release.

## Table of Contents

- [Features](#features)
- [Usage](#usage)
- [Versioning](#versioning)
- [Exposed variables](#exposed-variables)
- [Fingerprinting example](#fingerprinting-example)
- [Patch tiering](#patch-tiering)
- [Known caveats](#known-caveats)
- [Removed modules](#removed-modules)
- [Add modules back](#add-modules-back)
- [Force a no-fingerprint build](#force-a-no-fingerprint-build)
- [Use in another distribution](#use-in-another-distribution)
- [Recommended NGINX config](#recommended-nginx-config)

## Features

- Based on latest [NGINX](https://nginx.org/) **stable** version (gets every security release; check `nginx -v`)
- HTTP/3 and QUIC support, powered by native **OpenSSL 3.5 LTS** (patched; also enables `ssl_early_data` for QUIC — no quictls needed)
- TLS certificate compression (RFC 8879: zlib, brotli, zstd) — set `ssl_certificate_compression on;`
- JA3 / JA3 hash / JA4 TLS client fingerprinting, powered by [nginx-ssl-fingerprint](https://github.com/phuslu/nginx-ssl-fingerprint) (requires a patched OpenSSL + a patched nginx, applied automatically at build time)
- HTTP/2 fingerprinting (`SETTINGS` frame, priority, pseudo-headers)
- Brotli support, powered by [ngx_brotli](https://github.com/google/ngx_brotli)
- GeoIP2 support, powered by [ngx_http_geoip2_module](https://github.com/leev/ngx_http_geoip2_module)
- Headers More support, powered by [headers-more-nginx-module](https://github.com/openresty/headers-more-nginx-module)
- Full standard http module set from the nginx.org packaging (`auth_request`, `realip`, `stub_status`, `gzip_static`, `secure_link`, and the rest) — same set as the mainline build
- Remove mountains of useless modules to reduce attack surface

Packages are built for **amd64** only.

## Usage

```bash
wget https://github.com/Conceded2/nginx-fp/releases/latest/download/nginx.deb
sudo apt install ./nginx.deb
```

Each release also carries `nginx-dbg.deb` (debug symbols for `nginx` and `nginx-debug`), only needed to turn a core dump into a backtrace.

Note: `latest` occasionally points to a release built without the fingerprint module (its title ends in `no fingerprinting` — see [Patch tiering](#patch-tiering)). Check an installed binary with `nginx -V 2>&1 | grep -c nginx-ssl-fingerprint` (`1` = fingerprinted). If you *require* fingerprinting, pin a release whose title doesn't say `no fingerprinting`.

## Versioning

Releases have this repo's own version number, not nginx's (the same scheme as [nginx-http3](https://github.com/Conceded2/nginx-http3)). The title shows the nginx version inside, e.g. `v1.0.0 (nginx 1.30.7)`.

- The first release is `v1.0.0`.
- A push to `main` that changes the build (`build.sh`, `Dockerfile`, `patches/`, `.nofp`) bumps the minor number: `v1.0.3` → `v1.1.0`.
- Any other build that produces a different `.deb` (the daily run picking up a new nginx point release, a new OpenSSL 3.5.x or new module code) bumps the patch number: `v1.0.0` → `v1.0.1`.
- Builds whose `.deb` is unchanged publish nothing.

State files written by the workflow: `hash` (SHA256 of the last released `nginx.deb`), `nginx-version` (its nginx version, with `-nofp` when built without fingerprinting) and `release-version` (the last release number). Don't edit them by hand. Each release's notes carry the `.deb` SHA256, so an updater should compare SHA256s, not tags.

## Exposed variables

| Variable | Context | Description |
|---|---|---|
| `$http_ssl_ja3` | HTTP | Raw JA3 string |
| `$http_ssl_ja3_hash` | HTTP | MD5 hash of the JA3 string |
| `$http_ssl_ja4` | HTTP | JA4 fingerprint (`t13...` for TCP/TLS, `q13...` for QUIC clients) |
| `$http_ssl_greased` | HTTP | `1` if the client sent a GREASE extension |
| `$http2_fingerprint` | HTTP | HTTP/2 fingerprint (SETTINGS, priority, pseudo-headers, WINDOW_UPDATE) |

Stream variables are **not** available — the stream module family is removed in this build (see below).

Variables are empty for non-TLS connections.

## Fingerprinting example

```nginx
http {
  log_format fingerprint '$remote_addr [$time_local] "$request" $status '
                         'ja3="$http_ssl_ja3" ja3_hash="$http_ssl_ja3_hash" '
                         'ja4="$http_ssl_ja4" greased="$http_ssl_greased" '
                         'h2_fp="$http2_fingerprint"';

  server {
    listen 443 ssl;
    listen 443 quic;
    # ... TLS setup, see recommended config below ...
    location / {
      access_log /var/log/nginx/access.log fingerprint;

      # forward to your app / WAF / bot detection service:
      proxy_set_header X-SSL-JA3 $http_ssl_ja3;
      proxy_set_header X-SSL-JA4 $http_ssl_ja4;
      proxy_set_header X-HTTP2-Fingerprint $http2_fingerprint;
      proxy_pass http://127.0.0.1:8080;
    }
  }
}
```

## Patch tiering

[nginx-ssl-fingerprint](https://github.com/phuslu/nginx-ssl-fingerprint) needs version-specific patches for both nginx and OpenSSL, which upstream publishes shortly after each release. The build resolves a "tier" automatically:

| Tier | Condition | Result | Release title |
|---|---|---|---|
| 1 | Exact patch exists for the nginx version | Fully fingerprinted | `v1.0.1 (nginx 1.30.7)` |
| 2 | No exact patch, but a same-minor patch applies with fuzz | Fully fingerprinted; warning in release notes | `v1.0.1 (nginx 1.30.7)` |
| 3 | No applicable nginx *or* OpenSSL patch | Built **without** the fingerprint module (system libssl) | `v1.0.1 (nginx 1.30.7, no fingerprinting)` |

Security releases are **never delayed** by fingerprinting: tier 3 still ships the new nginx immediately, and the workflow fails loudly (after publishing) so the gap is visible. The same applies when the fingerprinted build fails for any other reason (a patch that applies but doesn't compile, a new OpenSSL that breaks, `patches/fp-87-quic-pool.patch` no longer applying): if the build contains a **new nginx version**, the workflow's fallback step rebuilds it without the fingerprint module and publishes it as a `no fingerprinting` release, then marks the run failed. If the nginx version is already released (an ordinary daily rebuild), nothing is published, so a one-off failure never replaces a working fingerprinted release; the run just fails. Once the cause is fixed (or phuslu publishes the matching patch), the next build returns to a fully fingerprinted release.

The fingerprint module itself is **pinned** to one commit (`FP_COMMIT` in `build.sh`), so its nginx/OpenSSL patches are the ones from that commit. Upstream changes never reach a build by surprise; see [Known caveats](#known-caveats) for why.

OpenSSL tracks the **3.5 LTS** line with no fuzz on the crypto library: the build uses the newest `openssl-3.5.x` release if the newest upstream OpenSSL patch applies to it with `--fuzz=0`, and otherwise falls back to the exact version that patch was written for. OpenSSL security releases are therefore picked up without waiting for a new patch.

The fingerprint module also gets one local patch, `patches/fp-87-quic-pool.patch` (see Known caveats). It is applied with `--fuzz=0` to the pinned commit; it only stops applying when `FP_COMMIT` is moved. Until that is sorted out, the current release stays in place, and new nginx versions ship without fingerprinting (see [Patch tiering](#patch-tiering)): the unpatched module is never shipped.

## Known caveats

- **The fingerprint module is pinned at [`e72f932`](https://github.com/phuslu/nginx-ssl-fingerprint/commit/e72f932b630717939b508b58e5b4a48ec014adf3) (2026-09-02).** On 2026-11-11 upstream changed how the fingerprints are computed: extensions are taken from the raw ClientHello (so unknown ones such as ECH GREASE count too), signature algorithms keep wire order, and the JA3 string sorts its extensions. That shifts JA4 part a **and** part c for every browser (measured: Edge 157 `t13d1514h2_8daaf6152771_ee79ac1fafef` → `t13d1516h2_8daaf6152771_806a8c22fdea`, Firefox 160 `t13d1515h2_…_74f33b40d17f` → `t13d1517h2_…_3cbfd9057e0d`; curl, Python and Schannel change part c), and every JA3 hash. Rules that match exact JA4 values would silently stop matching. The pinned commit's values are not the canonical FoxIO JA4 (part c hashes sorted signature algorithms), so don't compare them with public JA4 databases. Moving the pin means migrating those rules at the same time.
- [phuslu/nginx-ssl-fingerprint#87](https://github.com/phuslu/nginx-ssl-fingerprint/issues/87) is **fixed locally** for the pinned commit by `patches/fp-87-quic-pool.patch` (upstream has its own fix since 2026-11-11, PR 94, which comes with the changes above). On HTTP/3 the module cached the JA3/JA4 strings on the connection-shared `c->ssl` but allocated them from the per-stream pool, so every request after the first on a QUIC connection read freed memory (garbage fingerprints, leaked header bytes, occasional worker segfaults). The patch allocates them from the pool of the connection that owns the SSL object. Verified: 40/40 valid JA4 over one HTTP/3 connection (1/40 before). QUIC JA4 uses the `q` transport character.
- Tier 2 builds apply a patch written for an older point release with fuzz; it can (rarely) fail to compile even though it applies. If that happens on a new nginx version, the fallback step publishes a `no fingerprinting` build of it automatically and the run is marked failed.
- Chromium rotates TLS extension ordering and ALPS codepoints, which shifts JA3/JA4 for the same binary over time — that's the fingerprint, working as intended.

## Removed modules

- Nothing from the standard packaging module set — all optional http modules (`addition`, `auth_request`, `dav`, `flv`, `gunzip`, `gzip_static`, `mp4`, `random_index`, `realip`, `secure_link`, `slice`, `stub_status`, `sub`, `v2`, `v3`) are built, matching the mainline build. Mainline-only modules (e.g. `http_json_module`) do not exist in the stable branch.
- `http_autoindex_module`
- `http_browser_module`
- `http_charset_module`
- `http_empty_gif_module`
- `http_memcached_module`
- `http_mirror_module`
- `http_referer_module`
- `http_split_clients_module`
- `http_scgi_module`
- `http_ssi_module`
- `mail` and `mail_ssl_module`
- `stream`, `stream_realip_module`, `stream_ssl_module`, `stream_ssl_preread_module` — the fingerprint module is incompatible with dynamically built stream anyway, and this build hardens by omitting it entirely
- `select_module`, `poll_module`, `--with-compat`

## Add modules back

Fork this repo, enable GitHub Actions, edit `build.sh` and find the modules you want. Then remove related `--without-*` parameters from the `sed` lines and wait for GitHub Actions to run. After it finishes, you can download from releases.

For example, if you want to add `http_scgi_module` back, you need to remove `--without-http_scgi_module` from the mail/stream-removal `sed` line in `build.sh`.

If you add `stream` back, build it **statically** (`--with-stream`, not `--with-stream=dynamic`) — see [phuslu/nginx-ssl-fingerprint#89](https://github.com/phuslu/nginx-ssl-fingerprint/issues/89).

## Force a no-fingerprint build

Add an empty `.nofp` file at the repository root and push to `main`. The next build skips all fingerprint patching (tier 3) and publishes a `no fingerprinting` release. Delete the file to resume fingerprinted builds. Failed fingerprinted builds don't need it (the workflow falls back to a no-fingerprint build by itself); use it to turn fingerprinting off on purpose.

## Use in another distribution

Fork this repo, enable GitHub Actions, edit `Dockerfile` and `build.sh`, and change `trixie` to the one you like. Then wait for GitHub Actions to run. After it finishes, you can download from releases.

For example, if you want to use in Debian bookworm, you need to change `trixie` to `bookworm`.

Note: if you are using newer version of Debian (e.g. Debian testing or unstable), you can directly use this repo's pre-built releases because Debian is backward compatible.

## Recommended NGINX config

```nginx
http {
  brotli on;
  gzip on;
  http2 on;
  http3 on;
  quic_gso on;
  quic_retry on;
  ssl_certificate /path/to/cert_plus_intermediate;
  ssl_certificate_key /path/to/key;
  ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305; # change `ECDSA` to `RSA` if you use RSA certificate
  ssl_certificate_compression on;
  ssl_early_data on; # safe against replay only if your app is idempotent-tolerant; OpenSSL 3.5 makes this work for QUIC too
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_session_cache shared:SSL:10m;
  ssl_session_timeout 1d;
  log_format fingerprint '$remote_addr [$time_local] "$request" $status '
                         'ja3="$http_ssl_ja3" ja3_hash="$http_ssl_ja3_hash" '
                         'ja4="$http_ssl_ja4" greased="$http_ssl_greased" '
                         'h2_fp="$http2_fingerprint"';
  server {
    listen 80 reuseport;
    listen [::]:80 reuseport; # delete if ipv6 is unavailable
    return 444;
  }
  server {
    listen 443 reuseport ssl;
    listen [::]:443 reuseport ssl;
    listen 443 reuseport quic;
    listen [::]:443 reuseport quic;
    ssl_reject_handshake on; # default TLS server: rejects unknown SNI
  }
  server {
    listen 80;
    listen [::]:80;
    server_name example.com dynamic.example.com php.example.com www.example.com;
    return 308 https://$host$request_uri;
  }
  server { # example for static site
    listen 443;
    listen [::]:443;
    listen 443 quic;
    listen [::]:443 quic;
    server_name example.com;
    root /path/to/static/site;
    access_log /path/to/access.log fingerprint;
    add_header Alt-Svc 'h3=":443"; ma=86400';
  }
  server { # example for dynamic site
    listen 443;
    listen [::]:443;
    listen 443 quic;
    listen [::]:443 quic;
    server_name dynamic.example.com;
    access_log /path/to/access.log fingerprint;
    add_header Alt-Svc 'h3=":443"; ma=86400';
    location / {
      proxy_set_header X-SSL-JA3 $http_ssl_ja3;
      proxy_set_header X-SSL-JA4 $http_ssl_ja4;
      proxy_set_header X-HTTP2-Fingerprint $http2_fingerprint;
      proxy_pass http://ip:port;
    }
  }
  server { # example for dynamic site with php
    listen 443;
    listen [::]:443;
    listen 443 quic;
    listen [::]:443 quic;
    server_name php.example.com;
    root /path/to/php/site;
    index index.php;
    access_log /path/to/access.log fingerprint;
    add_header Alt-Svc 'h3=":443"; ma=86400';
    location ~ ^.+\.php$ {
      include fastcgi.conf;
      fastcgi_param HTTP_PROXY '';
      fastcgi_pass unix:/path/to/php/sock;
    }
  }
  server {
    listen 443;
    listen [::]:443;
    listen 443 quic;
    listen [::]:443 quic;
    server_name www.example.com;
    access_log /path/to/access.log fingerprint;
    add_header Alt-Svc 'h3=":443"; ma=86400';
    return 308 https://example.com$request_uri;
  }
}
```
