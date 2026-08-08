#!/usr/bin/env bash
# Template: rclone sync job + Uptime Kuma push heartbeat.
#
# Copy this file per job (rename it, e.g. gdrive-to-unraid.sh,
# github-to-gdrive.sh) rather than parameterizing one script with a
# config file — keeps each job's cron entry, log file, and Kuma monitor
# independently readable and independently disable-able.
#
# Covers legs 1, 3, 4, 5, 7 from Backup-Architecture.md — anything that's
# an rclone sync. Duplicati (leg 2) and MailStore Home (leg 6) use their
# own hook mechanisms; see the doc.

set -uo pipefail

# ---- fill these in per job ----
SRC="gdrive-personal:Backups"                                   # rclone remote:path
DST="onedrive-e5:Backups"                                       # rclone remote:path
LOGFILE="/mnt/user/backup-logs/gdrive-to-onedrive.log"
KUMA_PUSH_URL="http://192.168.1.10:3001/api/push/REPLACE_WITH_TOKEN"
# --------------------------------

# --backup-dir: anything rclone would overwrite or delete on the
# destination gets moved here instead of destroyed. This is what makes
# "sync" safe to use for a backup leg — a bad delete or a ransomware
# event on SRC can't silently wipe DST's history too.
BACKUP_DIR="${DST%%:*}:$(dirname "${DST#*:}")-versions/$(basename "${DST#*:}")/$(date +%F)"

mkdir -p "$(dirname "$LOGFILE")"
START_EPOCH=$(date +%s)

rclone sync "$SRC" "$DST" \
  --backup-dir "$BACKUP_DIR" \
  --log-file "$LOGFILE" --log-level INFO \
  --transfers 8 --checkers 16 \
  --contimeout 60s --timeout 300s --retries 3 \
  --stats 1m

RC=$?
DURATION=$(( $(date +%s) - START_EPOCH ))

if [ "$RC" -eq 0 ]; then
  curl -fsS -m 10 -G "$KUMA_PUSH_URL" \
    --data-urlencode "status=up" \
    --data-urlencode "msg=OK" \
    --data-urlencode "ping=${DURATION}000" >/dev/null
else
  ERRMSG=$(tail -n 1 "$LOGFILE" 2>/dev/null || echo "no log output")
  curl -fsS -m 10 -G "$KUMA_PUSH_URL" \
    --data-urlencode "status=down" \
    --data-urlencode "msg=rclone exit ${RC}: ${ERRMSG}" >/dev/null
fi

exit "$RC"
