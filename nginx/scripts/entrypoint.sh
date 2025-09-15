#!/usr/bin/env sh
set -eu

RELOADER_WATCH_DIRS="${RELOADER_WATCH_DIRS:-/etc/nginx/whitelists /etc/nginx/conf.d /etc/letsencrypt/live}"
RELOADER_PERIODIC_SECONDS="${RELOADER_PERIODIC_SECONDS:-21600}"  # 6h
RELOADER_DEBOUNCE_SECS="${RELOADER_DEBOUNCE_SECS:-10}"
RELOADER_SLEEP_SECS="${RELOADER_SLEEP_SECS:-2}"
RELOADER_COOLDOWN="${RELOADER_COOLDOWN:-20}"                      # min seconds between reloads
RELOADER_REQUIRE_DIRS="${RELOADER_REQUIRE_DIRS:-false}"          # exit if any listed path is missing

lock="/tmp/nginx.reload.lock"
stamp="/tmp/nginx.reload.stamp"

log(){ echo "[reloader] $*"; }
warn(){ echo "[reloader][warn] $*" >&2; }

reload_nginx() {
  if ! mkdir "$lock" 2>/dev/null; then
    log "reload already in progress, skipping"
    return 0
  fi
  log "reloading..."
  sleep "$RELOADER_SLEEP_SECS"

  now=$(date +%s); last=0
  [ -f "$stamp" ] && last=$(cat "$stamp" || echo 0)
  delta=$((now - last))
  if [ "$delta" -lt "$RELOADER_COOLDOWN" ]; then
    sleep "$((RELOADER_COOLDOWN - delta))"
  fi

  if nginx -t; then
    nginx -s reload && echo "$(date +%s)" > "$stamp"
    log "reload done"
  else
    warn "reload skipped, bad config"
  fi
  rm -rf "$lock"
}

# periodic safety net
(
  while :; do
    sleep "$RELOADER_PERIODIC_SECONDS"
    log "periodic reload"
    reload_nginx
  done
) &

# build watch list
LIST=""
missing=""
for d in $RELOADER_WATCH_DIRS; do
  if [ -d "$d" ]; then
    LIST="$LIST $d"
  else
    warn "missing: $d"
    missing="yes"
  fi
done

if [ "$RELOADER_REQUIRE_DIRS" = "true" ] && [ -n "$missing" ]; then
  warn "required paths missing, exiting"
  exit 1
fi

# Polling fallback: hash directory listings and compare
if [ -n "$LIST" ]; then
  log "polling for changes every ${RELOADER_DEBOUNCE_SECS}s"
  hash_dirs() {
    # Portable hash using find + ls + md5sum
    # shellcheck disable=SC2086
    find $LIST -type f 2>/dev/null -print0 \
      | xargs -0 ls -ld 2>/dev/null \
      | md5sum | awk '{print $1}'
  }
  PREV="$(hash_dirs || true)"
  (
    while :; do
      sleep "$RELOADER_DEBOUNCE_SECS"
      CURR="$(hash_dirs || true)"
      if [ "$CURR" != "$PREV" ]; then
        log "change detected (poll)"
        PREV="$CURR"
        reload_nginx
      fi
    done
  ) &
else
  warn "no existing watch dirs, watcher disabled"
fi

# run Nginx in foreground
exec nginx -g "daemon off;"
