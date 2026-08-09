#!/usr/bin/env bash
# gdriveX-to-onedriveX.sh — Leg 1 (Backup-Architecture.md): Google Drive EDU
# account #2 -> OneDrive E5 account #2, daily.
#
# Sibling to gdrive-to-onedrive.sh -- same shape, second account pair, its
# own hand-picked folder list (this account's folders don't overlap with
# the first account's). Runs on zrh-tool.
#
# Deploy: crontab entry below installs this to run once a day.
#   0 4 * * * /root/router/backup/gdriveX-to-onedriveX.sh

set -uo pipefail

# ---- config ----
SRC="gdriveX:"
DST="onedriveX:"
RCLONE_CONFIG="/root/.config/rclone/rclone.conf"
LOGFILE="/var/log/gdriveX-to-onedriveX.log"
KUMA_PUSH_URL=""   # from Uptime Kuma, monitor: gdriveX-to-onedriveX
LOCKFILE="/var/run/gdriveX-to-onedriveX.lock"

# Top-level Drive folders to sync -- add/remove here, not the whole Drive
# root. Each entry becomes a --include "/<folder>/**" flag below.
FOLDERS=(
  "Blackmail"
  "Books"
  "Drawings"
  "Dream House"
  "Gear Measurement & Care"
  "Hypnosis"
  "I want"
  "My Pics"
  "My S"
  "My Videos"
  "PE"
  "Pics"
  "Published Pics"
  "S"
  "SS"
  "Stories"
  "Tasker"
  "Tattoos"
  "To Try"
  "Tom of Finland"
  "TravelGuide"
  "Video"
  "Z - Archive"
)
# ----------------

exec 9>"$LOCKFILE"
flock -n 9 || { echo "Sync already running — exiting."; exit 1; }

INCLUDE_ARGS=()
for f in "${FOLDERS[@]}"; do
  INCLUDE_ARGS+=(--include "/${f}/**")
done

# --backup-dir: anything rclone would overwrite or delete on the
# destination gets moved here instead of destroyed, dated per run.
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
