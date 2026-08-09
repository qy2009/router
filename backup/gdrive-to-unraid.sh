#!/usr/bin/env bash
# gdrive-to-unraid.sh — Leg 2 (Backup-Architecture.md): Google Drive EDU
# account #1 -> local Unraid array (rui-server), weekly.
#
# Sibling to gdrive-to-onedrive.sh, but the destination is a local
# filesystem path on the Unraid box instead of a remote:path. Only syncs a
# hand-picked set of top-level folders (via --include), not the entire
# Drive root. Runs on rui-server (10.0.0.2) itself via cron.
#
# Deploy: registered via the Unraid User Scripts plugin (not raw crontab
# -- that gets wiped on reboot/array events on Unraid), custom schedule.
# Runs Sunday 1:00am, 30 min before gdriveX-to-unraid.sh and 3 hours
# before gdrive-to-onedrive.sh's daily 4:00am run on zrh-tool, so the two
# never overlap.
#   0 1 * * 0 /root/router/backup/gdrive-to-unraid.sh

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
# destination gets moved here instead of destroyed, dated per run. Lives
# under ZZ-Versions (sorts to the bottom of the share) rather than being
# deleted -- safe to nest inside $DST here because the --include list
# above only ever touches All/, Android/, Backup_Blog/, Backup_CloudVPS/,
# ID/, so this sync never looks at ZZ-Versions and can't sweep it up.
BACKUP_DIR="/mnt/user/data/ZZ-Versions/$(date +%F)"

mkdir -p "$(dirname "$LOGFILE")" "$DST"
START_EPOCH=$(date +%s)

# --drive-acknowledge-abuse: a handful of files on this Drive account get
# flagged by Google's automated scanner as "malware or spam" (mostly old
# cracked installers/APKs) and 403 without this flag -- same files that
# broke gdrive-to-onedrive.sh. Ray owns these files and wants them backed
# up regardless.
rclone sync "$SRC" "$DST" \
  "${INCLUDE_ARGS[@]}" \
  --backup-dir "$BACKUP_DIR" \
  --config "$RCLONE_CONFIG" \
  --log-file "$LOGFILE" --log-level INFO \
  --transfers 8 --checkers 16 \
  --drive-acknowledge-abuse \
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
