#!/usr/bin/env bash
set -euo pipefail

CONFIG="/config/targets.json"
SOCK="${DOCKER_SOCK:-}"   # optional

log(){ echo "[whitelist] $*"; }
err(){ echo "[whitelist][error] $*" >&2; }

# IPv4, IPv6, with optional CIDR
ip_or_cidr_re='^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$|^[0-9A-Fa-f:]+(/[0-9]{1,3})?$'
is_ip_or_cidr(){ printf '%s' "$1" | grep -Eq "$ip_or_cidr_re"; }

reload_notice() {
  local container="$1" action="$2"
  if [[ -z "$container" ]]; then
    log "reload not configured (${action}). Assuming external script handles nginx reload."
    return 0
  fi
  if [[ -n "$SOCK" && -S "$SOCK" ]]; then
    local cid
    cid=$(curl -s --unix-socket "$SOCK" http:/containers/json \
          | jq -r ".[] | select(.Names[]==\"/${container}\") | .Id" | head -n1)
    if [[ -n "$cid" ]]; then
      if curl -s -X POST --unix-socket "$SOCK" "http:/containers/${cid}/kill?signal=HUP" >/dev/null; then
        log "sent HUP to ${container} (${action})"
      else
        err "failed to HUP ${container} via Docker socket (${action})"
      fi
    else
      err "container ${container} not found via Docker socket (${action})"
    fi
  } else
    log "no DOCKER_SOCK provided or not a socket (${action}). Assuming external script handles nginx reload."
  fi
}

# run lock
LOCK="/tmp/whitelist.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  log "another run is in progress, skipping"
  exit 0
fi
trap 'r=$?; rm -rf "$LOCK"; exit $r' EXIT

if [[ ! -f "$CONFIG" ]]; then
  err "missing $CONFIG"
  exit 1
fi

jq -c '.[]' "$CONFIG" | while read -r item; do
  OUT=$(jq -r '.out' <<<"$item")
  IPV6=$(jq -r '.ipv6 // false' <<<"$item")
  DENY_ALL=$(jq -r '.deny_all // true' <<<"$item")
  CONTAINER=$(jq -r '.reload.container // empty' <<<"$item")

  mapfile -t HOST_ITEMS < <(jq -r '.hosts[]' <<<"$item")

  if [[ -z "$OUT" || ${#HOST_ITEMS[@]} -eq 0 ]]; then
    err "skipping invalid item, need 'out' and at least one host"
    continue
  fi

  TMP="$(mktemp)"
  TMP_ALLOW="$(mktemp)"
  echo "# Auto generated $(date -u +'%Y-%m-%dT%H:%M:%SZ')" > "$TMP"

  dns_failed_list=()
  allow_count=0

  for H in "${HOST_ITEMS[@]}"; do
    if is_ip_or_cidr "$H"; then
      echo "allow $H;" >> "$TMP_ALLOW"
      allow_count=$((allow_count+1))
      continue
    fi

    A_REC=$(dig +short A "$H" | grep -E '^[0-9.]+' || true)
    AAAA_REC=""
    if [[ "$IPV6" == "true" ]]; then
      AAAA_REC=$(dig +short AAAA "$H" | grep -E '^[0-9A-Fa-f:]+' || true)
    fi

    if [[ -z "$A_REC" && -z "$AAAA_REC" ]]; then
      dns_failed_list+=("$H")
      continue
    fi

    for ip in $A_REC $AAAA_REC; do
      echo "allow $ip;" >> "$TMP_ALLOW"
      allow_count=$((allow_count+1))
    done
  done

  # Log DNS failures
  if [[ ${#dns_failed_list[@]} -gt 0 ]]; then
    err "DNS resolution returned no A or AAAA for: ${dns_failed_list[*]}"
  fi

  # Always generate the file. If no allows, write a safe, valid file.
  if [[ -s "$TMP_ALLOW" ]]; then
    sort -u "$TMP_ALLOW" >> "$TMP"
  else
    echo "# No allow entries generated. File kept to avoid Nginx include failure." >> "$TMP"
  fi
  rm -f "$TMP_ALLOW"

  [[ "$DENY_ALL" == "true" ]] && echo "deny all;" >> "$TMP"

  # Replace only on change
  if [[ ! -f "$OUT" ]] || ! cmp -s "$TMP" "$OUT"; then
    mkdir -p "$(dirname "$OUT")"
    mv "$TMP" "$OUT"
    log "updated $OUT"
    reload_notice "$CONTAINER" "after update"
  else
    rm -f "$TMP"
  fi
done
