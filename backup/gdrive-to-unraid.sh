#!/usr/bin/env bash
# gdrive-to-unraid.sh — Leg 2 (Backup-Architecture.md): Google Drive EDU
# account #1 -> local Unraid array (rui-server), weekly.
#
# Sibling to gdrive-to-onedrive.sh, but the destination is a local
# filesystem path on the Unraid box instead of a remote:path. Only syncs a
# hand-picked set of top-level folders (via --include), not the entire
# Drive root. Runs on rui-server (10.0.0.2) itself via cron.
#
# Deploy: crontab entry below installs this to run once a week.
#   0 3 * * 0 /root/router/backup/gdrive-to-unraid.sh

set -uo pipefail

# ---- config ----
SRC="gdrive:"
DST="/mnt/user/data"
RCLONE_CONFIG="/root/.config/rclone/rclone.conf"
LOGFILE="/mnt/user/mylogs/gdrive-to-unraid.log"
KUMA_PUSH_URL="http://100.111.111.117:3001/api/push/a0L1xaOHUn"   # Kuma monitor: gdrive-to-unraid (Tailscale IP -- sjc-tool hosts Kuma)
LOCKFILE="/var/run/gdrive-to-unraid.lock"

# Top-level Drive folders to sync -- add/remove here, not the whole Drive
# root. Each entry becomes a --include "/<folder>/**" flag below.
FOLDERS=(
  "All"
  "Android"
  "Backup_Blog"
  "Backup_CloudVPS"
  "ID"
)
# ----------------

exec 9>"$LOCKFILE"
flock -n 9 || { echo "Sync already running — exiting."; exit 1; }

INCLUDE_ARGS=()
for f in "${FOLDERS[@]}"; do
  INCLUDE_ARGS+=(--include "/${f}/**")
done

# --backup-dir: anything rclone would overwrite or delete on the
# destination gets moved here instead of destroyed, dated per run. Kept as
# a sibling of $DST (not nested inside it) so it never gets swept up by a
# later sync pass. This is what makes "sync" safe here -- a bad delete or
# unexpected change on the Drive side can't silently wipe the local copy.
BACKUP_DIR="/mnt/user/data-versions/$(date +%F)"

mkdir -p "$(dirname "$LOGFILE")" "$DST"
START_EPOCH=$(date +%s)

rclone sync "$SRC" "$DST" \
  "${INCLUDE_ARGS[@]}" \
  --backup-dir "$BACKUP_DIR" \
  --config "$RCLONE_CONFIG" \
  --log-file "$LOGFILE" --log-level INFO \
  --transfers 8 --checkers 16 \
  --contimeout 60s --timeout 300s --retries 3 \
  --stats 1m

RC=$?
DURATION=$(( $(date +%s) - START_EPOCH ))

if [ "$RC" -eq 0 ]; then
  [ -n "$KUMA_PUSH_URL" ] && curl -fsS -m 10 -G "$KUMA_PUSH_URL" \
    --data-urlencode "status=up" \
    --data-urlencode "msg=OK" \
    --data-urlencode "ping=${DURATION}000" >/dev/null
else
  ERRMSG=$(tail -n 1 "$LOGFILE" 2>/dev/null || echo "no log output")
  [ -n "$KUMA_PUSH_URL" ] && curl -fsS -m 10 -G "$KUMA_PUSH_URL" \
    --data-urlencode "status=down" \
    --data-urlencode "msg=rclone exit ${RC}: ${ERRMSG}" >/dev/null
fi

exit "$RC"
