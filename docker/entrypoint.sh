#!/usr/bin/env bash
set -euo pipefail

# Create cron job
CRON_LINE="${RUN_EVERY} /app/update-whitelists.sh >> /proc/1/fd/1 2>&1"
echo "$CRON_LINE" > /etc/crontabs/root

# Run once at start, then cron in foreground
/app/update-whitelists.sh || true
exec crond -f -l 8