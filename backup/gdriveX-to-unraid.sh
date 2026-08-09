#!/usr/bin/env bash
# gdriveX-to-unraid.sh — Leg 2 (Backup-Architecture.md): Google Drive EDU
# account #2 -> local Unraid array (rui-server), weekly.
#
# Sibling to gdrive-to-unraid.sh, second Drive account. Unlike that script,
# this mirrors the *entire* gdriveX: root (minus one excluded folder)
# rather than a hand-picked folder list, since Ray wants everything on
# this account synced. Runs on rui-server (10.0.0.2) itself via cron.
#
# Deploy: registered via the Unraid User Scripts plugin (not raw crontab
# -- that gets wiped on reboot/array events on Unraid), custom schedule.
# Runs Sunday 1:30am, 30 min after gdrive-to-unraid.sh, well clear of
# gdrive-to-onedrive.sh's daily 4:00am run on zrh-tool.
#   30 1 * * 0 /root/router/backup/gdriveX-to-unraid.sh

set -uo pipefail

# ---- config ----
SRC="gdriveX:"
DST="/mnt/user/data/X"
RCLONE_CONFIG="/root/.config/rclone/rclone.conf"
LOGFILE="/mnt/user/mylogs/gdriveX-to-unraid.log"
KUMA_PUSH_URL="http://100.111.111.117:3001/api/push/U3d1pSHY66"   # Kuma monitor: gdriveX-to-unraid (Tailscale IP -- sjc-tool hosts Kuma)
LOCKFILE="/var/run/gdriveX-to-unraid.lock"
# ----------------

exec 9>"$LOCKFILE"
flock -n 9 || { echo "Sync already running — exiting."; exit 1; }

# --backup-dir: anything rclone would overwrite or delete on the
# destination gets moved here instead of destroyed, dated per run. This
# job mirrors ALL of $DST (no --include filter), so the versions folder
# has to live somewhere it'll never see as part of $DST -- otherwise each
# run would find last run's versions folder "not in source" and
# re-backup-dir it into itself, nesting forever. The mylogs share is
# outside /mnt/user/data entirely, so that's a non-issue here.
BACKUP_DIR="/mnt/user/mylogs/ZZ-Versions/X/$(date +%F)"

mkdir -p "$(dirname "$LOGFILE")" "$DST"
START_EPOCH=$(date +%s)

rclone sync "$SRC" "$DST" \
  --exclude "/.luckybackup-snaphots/**" \
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
