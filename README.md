# nginx-fp

Debian packages of [NGINX](https://nginx.org/) (**stable branch**) with **HTTP/3/QUIC** and **TLS client fingerprinting** ([JA3](https://github.com/salesforce/ja3)/[JA4](https://github.com/FoxIO-LLC/ja4) + HTTP/2 fingerprint), auto-rebuilt by GitHub Actions on every stable nginx release.

## Table of Contents

- [Features](#features)
- [Usage](#usage)
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
- JA3 / JA3 hash / JA4 TLS client fingerprinting, powered by [nginx-ssl-fingerprint](https://github.com/phuslu/nginx-ssl-fingerprint) (requires a patched OpenSSL + a patched nginx, applied automatically at build time)
- HTTP/2 fingerprinting (`SETTINGS` frame, priority, pseudo-headers)
- Brotli support, powered by [ngx_brotli](https://github.com/google/ngx_brotli)
- GeoIP2 support, powered by [ngx_http_geoip2_module](https://github.com/leev/ngx_http_geoip2_module)
- Headers More support, powered by [headers-more-nginx-module](https://github.com/openresty/headers-more-nginx-module)
- Remove mountains of useless modules to reduce attack surface

Packages are built for **amd64** only.

## Usage

```bash
wget https://github.com/Conceded2/nginx-fp/releases/latest/download/nginx.deb
sudo apt install ./nginx.deb
```

Note: `latest` occasionally points to a `vX.Y.Z-nofp` release (built without the fingerprint module — see [Patch tiering](#patch-tiering)). If you *require* fingerprinting, pin a release tag without the `-nofp` suffix.

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

| Tier | Condition | Result | Release tag |
|---|---|---|---|
| 1 | Exact patch exists for the nginx version | Fully fingerprinted | `v1.30.7` |
| 2 | No exact patch, but a same-minor patch applies with fuzz | Fully fingerprinted; warning in release notes | `v1.30.7` |
| 3 | No applicable nginx *or* OpenSSL patch | Built **without** the fingerprint module (system libssl) | `v1.30.7-nofp` |

Security releases are **never delayed** by fingerprinting: tier 3 still ships the new nginx immediately, and the workflow fails loudly (after publishing) so the gap is visible. Once phuslu publishes the matching patch, the next daily build returns to a fully fingerprinted release.

OpenSSL tracks the **3.5 LTS** line and only uses versions that have an exact patch (no fuzz on the crypto library).

## Known caveats

- [phuslu/nginx-ssl-fingerprint#87](https://github.com/phuslu/nginx-ssl-fingerprint/issues/87): Chrome over HTTP/3/QUIC can intermittently report corrupt fingerprints (streams on one QUIC connection share `c->ssl`). Until fixed upstream, prefer trusting JA4 from HTTP/1.1/HTTP/2 traffic. JA4 correctly uses the `q` transport character for QUIC otherwise.
- Tier 2 builds apply a patch written for an older point release with fuzz; it can (rarely) fail to compile even though it applies. If that happens, the workflow fails and no release is published — push a commit with an empty `.nofp` file to force a tier-3 build of the security release (see below).
- Chromium rotates TLS extension ordering and ALPS codepoints, which shifts JA3/JA4 for the same binary over time — that's the fingerprint, working as intended.

## Removed modules

- All modules that are not built by default, except `http_ssl_module`, `http_v2_module` and `http_v3_module`
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

Add an empty `.nofp` file at the repository root and push to `main`. The next build skips all fingerprint patching (tier 3) and publishes a `vX.Y.Z-nofp` release. Delete the file to resume fingerprinted builds. This is the escape hatch if a fuzzed patch ever fails to compile right after a security release.

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
