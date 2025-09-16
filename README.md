# nginx-dns-whitelist

Small Dockerized toolchain to keep Nginx `allow` rules in sync with DNS names.
It writes one `include` file per target and reloads Nginx safely only when content changes.
Works on Alpine or Debian based images.

## Features

* Resolve A and optional AAAA records for hostnames and write `allow` lines
* Accept literal IPs and CIDRs alongside hostnames
* One or many output files in a single JSON config
* Always writes a valid include file so Nginx reloads never fail
* Safe reload strategy:

    * Recommended: reload from **inside** the Nginx container with an entrypoint watcher
    * Optional: reload via Docker Engine API if you choose to mount the Docker socket

---

## Repository layout

```
.
├─ config/
│  └─ targets.json          # mapping from hostnames/IPs → whitelist include files
├─ nginx/
│  ├─ conf.d/               # your server blocks
│  └─ scripts/
│     └─ entrypoint.sh      # portable file-change watcher + safe Nginx reloader
├─ docker-compose.yml
├─ Dockerfile               # updater image (resolves DNS → allowlines)
├─ LICENSE
└─ README.md
```

---

## How it works

1. The **updater container** reads `config/targets.json`, resolves DNS names to IPs, merges with any literal IPs/CIDRs, deduplicates, and writes `allow ...;` lines plus an optional `deny all;` into the requested output files (mounted volume).
2. Your **Nginx container** includes those files, and a small entrypoint script watches for changes and runs `nginx -t && nginx -s reload` with debouncing and locking.

> For security reasons, prefer the entrypoint-based reload inside the Nginx container.
> The Docker socket mount is optional and should be avoided unless you need the updater to trigger reloads itself.

---

## Quick start

### 1) targets.json

`config/targets.json` supports hostnames, IPs, and CIDRs. `ipv6` enables AAAA lookups per target.

```json
[
  {
    "out": "/whitelists/admin.conf",
    "hosts": [
      "admin.example.net",
      "192.0.2.0/24",
      "192.168.1.10",
      "2001:470:1f13:abcd::/64"
    ],
    "ipv6": true,
    "deny_all": true,

    // Optional reloader integration. If omitted, the updater only writes files
    // and logs that reload is handled externally (recommended).
    "reload": { "container": "nginx" }
  }
]
```

What gets generated (example):

```nginx
# Auto generated 2025-09-15T12:34:56Z
allow 192.0.2.0/24;
allow 192.168.1.10;
allow 2001:470:1f13:abcd::/64;
deny all;
```

If no IPs are found, the file still exists with a header (and optional `deny all;`) so that Nginx reloads do not fail.

### 2) Example Nginx server block

`nginx/conf.d/00-default.conf`

```nginx
server {
  listen 80 default_server;
  server_name _;

  error_page 403 =404 /404.html;
  location = /404.html { internal; return 404; }

  # Public page
  location = / {
    root /usr/share/nginx/html;
    try_files /index.html =404;
  }

  # Protected path
  location /admin/ {
    include /etc/nginx/whitelists/admin.conf;  # allow ...; deny all;
    root /usr/share/nginx/html;
    try_files /admin.html =404;
  }
}
```

> Tip: Do not use `return 200 ...` inside a protected location. `return` bypasses access checks. Serve a file or proxy instead.

### 3) docker-compose.yml - recommended setup

Nginx reloads itself on file changes using `nginx/scripts/entrypoint.sh`. The updater only writes files.

```yaml
version: "3.9"

volumes:
  whitelists:

services:
  nginx:
    image: nginx:alpine
    container_name: nginx
    volumes:
      - whitelists:/etc/nginx/whitelists
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - ./nginx/scripts:/scripts:ro
      - ./nginx/html:/usr/share/nginx/html:ro
    command: ["/bin/sh","-lc","/scripts/entrypoint.sh"]
    environment:
      - RELOADER_WATCH_DIRS=/etc/nginx/whitelists /etc/nginx/conf.d /etc/letsencrypt/live
      - RELOADER_PERIODIC_SECONDS=21600
      - RELOADER_DEBOUNCE_SECS=10
      - RELOADER_SLEEP_SECS=2
      - RELOADER_COOLDOWN=20
      - RELOADER_REQUIRE_DIRS=false
    ports:
      - "8080:80"

  whitelist-updater:
    build: .
    container_name: whitelist-updater
    volumes:
      - whitelists:/whitelists
      - ./config/targets.json:/config/targets.json:ro
    # No Docker socket here. Reload is done by Nginx entrypoint watcher.
```

### 4) Alternative: updater triggers reload via Docker socket

If you really want the updater to send SIGHUP to the Nginx container:

```yaml
  whitelist-updater:
    build: .
    container_name: whitelist-updater
    environment:
      - DOCKER_SOCK=/var/run/docker.sock
    volumes:
      - whitelists:/whitelists
      - ./config/targets.json:/config/targets.json:ro
      - /var/run/docker.sock:/var/run/docker.sock
```

> Security note: mounting the Docker socket gives the container root-equivalent control of the host’s Docker. Prefer the entrypoint watcher whenever possible.

---

## Environment variables

### For the Nginx entrypoint reloader (inside the Nginx container)

* `RELOADER_WATCH_DIRS`
  Space separated list of directories to watch for changes.
  Default: `/etc/nginx/whitelists /etc/nginx/conf.d /etc/letsencrypt/live`

* `RELOADER_WATCH_EXTS`
  Space separated list of file extensions to include when checking for changes.
  You can write them with or without the leading dot.
  Default: .conf .pem

* `RELOADER_PERIODIC_SECONDS`
  Periodic safety reload even if no changes were detected.
  Default: `21600` (6 hours)

* `RELOADER_DEBOUNCE_SECS`
  Debounce window before reloading after a change event.
  Default: `10`

* `RELOADER_SLEEP_SECS`
  Grace period before triggering a reload, allowing changes to settle and reducing flapping.
  Default: `2`

* `RELOADER_COOLDOWN`
  Minimum seconds between two reloads to avoid thrashing.
  Default: `20`

* `RELOADER_REQUIRE_DIRS`
  If `true`, the script exits when any directory in `RELOADER_WATCH_DIRS` is missing.
  Default: `false` (missing paths are logged and skipped)

### For the updater container

* `DOCKER_SOCK`
  Optional path to the Docker socket. When provided and the JSON target includes `"reload": {"container":"<name>"}`, the updater will send `SIGHUP` to that container after changes.
  If empty or not a socket, the updater logs that reload is handled externally.
  Default: empty

You may also set `TZ` in either container for logs, e.g. `TZ=Europe/Zurich`.

---

## targets.json schema

Each array item:

* `out` **(string, required)**
  Absolute path to the generated include file inside the shared volume, for example `/whitelists/admin.conf`.

* `hosts` **(array of strings, required)**
  Each item can be a DNS name, an IPv4/IPv6 literal, or a CIDR.

* `ipv6` **(bool, optional)**
  If `true`, resolve AAAA records in addition to A. Default: `false`.

* `deny_all` **(bool, optional)**
  Append `deny all;` at the end of the file. Default: `true`.

* `reload.container` **(string, optional)**
  Name of the Nginx container to send SIGHUP to after updates when `DOCKER_SOCK` is mounted.
  If omitted, the updater only writes files and logs that reload is handled externally.

---

## Configuration patterns

* **Protect the whole site**
  Include your generated file at the server level:

  ```nginx
  server {
    listen 80 default_server;
    include /etc/nginx/whitelists/site.conf;
    # locations...
  }
  ```

* **Protect only a path**
  Include inside that `location`:

  ```nginx
  location /admin/ {
    include /etc/nginx/whitelists/admin.conf;
    proxy_pass http://backend; # or serve a file
  }
  ```

* **Behind a reverse proxy**
  Make sure Nginx sees the real client IP or your allow rules will match the proxy:

  ```nginx
  set_real_ip_from 10.0.0.0/8;  # your proxy ranges
  real_ip_header X-Forwarded-For;
  real_ip_recursive on;
  ```

* **Wildcard include**
  You can include many generated files:

  ```nginx
  include /etc/nginx/whitelists/*.conf;
  ```

---

## Troubleshooting

* **Localhost can access the protected path**
  Ensure you are not using `return 200 ...` inside the protected `location`. Serve a file or proxy. `return` short-circuits access checks.

* **No reload after updater runs**
  This is expected if you did not mount the Docker socket. Nginx should still reload via the entrypoint watcher when the file changes.

* **DNS name does not resolve**
  The updater logs an error and still writes a valid include file so reloads do not fail. Check your DNS and `ipv6` flag.

* **Permission denied running entrypoint.sh**
  Make the file executable and ensure LF line endings:

  ```bash
  chmod +x nginx/scripts/entrypoint.sh
  sed -i 's/\r$//' nginx/scripts/entrypoint.sh
  ```

---

## Development

Build and run:

```bash
docker compose up -d --build
docker compose logs -f whitelist-updater
```

Update `targets.json` and watch the Nginx container reload when the whitelist changes.

---

## License

MIT. See `LICENSE`.

---

## Security note

For security reasons, it is better to reload Nginx from inside the Nginx container with `nginx/scripts/entrypoint.sh`.
Avoid mounting the Docker socket. If you must, use:

```yaml
# Optional and not recommended by default
# DOCKER_SOCK=/var/run/docker.sock
# volumes:
#   - /var/run/docker.sock:/var/run/docker.sock
```
