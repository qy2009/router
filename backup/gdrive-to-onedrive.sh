#!/usr/bin/env bash
# gdrive-to-onedrive.sh — Leg 1 (Backup-Architecture.md): Google Drive EDU
# account #1 -> OneDrive E5 account #1, daily.
#
# Copied from rclone-backup-template.sh and customized: unlike a whole-drive
# mirror, this only syncs a hand-picked set of top-level folders (via
# --include), not the entire Drive root. Runs on zrh-tool.
#
# Deploy: crontab entry below installs this to run once a day.
#   0 4 * * * /root/router/backup/gdrive-to-onedrive.sh

set -uo pipefail

# ---- config ----
SRC="gdrive:"
DST="onedrive:"
RCLONE_CONFIG="/root/.config/rclone/rclone.conf"
LOGFILE="/var/log/gdrive-to-onedrive.log"
KUMA_PUSH_URL="http://100.111.111.117:3001/api/push/exHuCHPJ6g"   # Kuma monitor: gdrive-to-onedrive (Tailscale IP -- must be reachable from every VPS, not the public dashboard URL)
LOCKFILE="/var/run/gdrive-to-onedrive.lock"

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
# destination gets moved here instead of destroyed, dated per run. This is
# what makes "sync" safe here -- a bad delete or unexpected change on the
# Drive side can't silently wipe OneDrive's copy too.
BACKUP_DIR="${DST}_sync-versions/$(date +%F)"

mkdir -p "$(dirname "$LOGFILE")"
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
