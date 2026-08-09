#!/bin/bash
# backup-agent-wordpress.sh — restic backup agent for native (non-Docker)
# OpenLiteSpeed + WordPress + MariaDB boxes.
#
# Sibling to backup-agent.sh (the Docker-fleet version). Same restic/rclone
# backbone, same retention policy, same Pushover/email/Kuma alerting — the
# only real difference is how a *consistent* snapshot gets taken, since
# there are no containers here to stop:
#   - Docker fleet:  stop every container, snapshot, restart.
#   - This script:   mysqldump --single-transaction (InnoDB-safe, no
#                     locking, no downtime), then back that dump up
#                     alongside the web root and the OpenLiteSpeed vhost
#                     configs.
#
# Backend is deliberately NOT gdrive here — see RCLONE_REMOTE below. This
# reuses the SAME "oracle" rclone remote (Oracle Object Storage, S3-compat)
# that's already in the shared secrets-bundle.tar.age rclone.conf — no new
# credentials needed, just a dedicated bucket for this leg.
#
# Deploy via install-backup-agent-wordpress.sh, which drops this file at
# /usr/local/bin/backup-agent.sh — same install path as every other host,
# so RECOVERY.md and the cron pattern stay uniform across the whole fleet
# regardless of which variant a given box is running.
#
# Usage: invoked by cron. Run by hand for testing:
#   /usr/local/bin/backup-agent.sh

set -uo pipefail
# Not -e: several steps here are intentionally best-effort. The steps that
# matter (mysqldump, restic backup, restic forget) check their own exit
# codes and are reflected in the final success/failure report.

LOCKFILE="/var/run/backup-agent.lock"
exec 9>"$LOCKFILE"
flock -n 9 || { echo "Backup already running — exiting."; exit 1; }

# ---- defaults, overridable in /etc/backup-agent.conf ----
HOST_LABEL="$(hostname)"
WEBROOT="/var/www"
LSWS_CONF_DIR="/usr/local/lsws/conf/vhosts"
DUMP_DIR="/var/backups/mysql-dumps"
LOGFILE="/var/log/backup-agent.log"
EXCLUDE_FILE="/etc/backup-agent/excludes.txt"
SECRETS_FILE="/etc/backup-agent/secrets.env"
RCLONE_REMOTE="oracle"        # rclone remote name. Docker fleet uses "gdrive";
                              # this host backs up to Oracle Object Storage,
                              # reusing the "oracle" remote already in the
                              # shared rclone.conf (see secrets-bundle.tar.age).
RCLONE_PATH=""                 # defaults to vps-backups/Backup_CloudVPS/<hostname>
UPLOAD_LOG=true               # copy the log to the remote after each run
RETENTION="--keep-weekly 8 --keep-monthly 6 --keep-yearly 2"
KUMA_PUSH_URL=""
PUSHOVER_NOTIFY_SUCCESS=true
EMAIL_RECIPIENT=""
MYSQL_USER="root"              # this box's root MariaDB user has no password
                                # set (mysql_native_password, blank) -- if you
                                # lock that down later, set MYSQL_PASSWORD in
                                # secrets.env instead of putting it here.

CONF="/etc/backup-agent.conf"
[ -f "$CONF" ] && source "$CONF"

if [ -z "$RCLONE_PATH" ]; then
    RCLONE_PATH="vps-backups/Backup_CloudVPS/${HOST_LABEL}"
fi
export RESTIC_REPOSITORY="rclone:${RCLONE_REMOTE}:${RCLONE_PATH}"

# ---- secrets ----
if [ -f "$SECRETS_FILE" ]; then
    source "$SECRETS_FILE"
else
    echo "Missing $SECRETS_FILE — aborting." >&2
    exit 1
fi

mkdir -p "$(dirname "$LOGFILE")" "$DUMP_DIR"
exec >>"$LOGFILE" 2>&1
echo "===== [$HOST_LABEL] Backup run started: $(date) ====="

send_alert() {
    local STATUS=$1 MSG=$2
    [ -n "${PUSHOVER_TOKEN:-}" ] && curl -s --form-string "token=$PUSHOVER_TOKEN" --form-string "user=$PUSHOVER_USER" \
        --form-string "title=${HOST_LABEL} Backup $STATUS" --form-string "message=$MSG" \
        https://api.pushover.net/1/messages.json >/dev/null
}

send_failure_email() {
    [ -z "$EMAIL_RECIPIENT" ] && return 0
    command -v ssmtp >/dev/null 2>&1 || return 0
    {
        echo "Subject: [${HOST_LABEL}] Backup FAILED $(date +%F)"
        echo ""
        echo "Backup failed on ${HOST_LABEL}. Last 50 log lines from ${LOGFILE}:"
        echo "----------------------------------------------------------------"
        tail -n 50 "$LOGFILE"
    } | ssmtp "$EMAIL_RECIPIENT"
}

mkdir -p "$(dirname "$EXCLUDE_FILE")"
[ -f "$EXCLUDE_FILE" ] || { echo "WARNING: $EXCLUDE_FILE missing — creating empty one."; touch "$EXCLUDE_FILE"; }
# restic errors out (not skips) if --exclude-file doesn't exist.

# ---- dump every database: --single-transaction means no table locking,  ----
# ---- so this is safe to run against a live site, unlike a raw file copy ----
# ---- of MariaDB's data directory.                                       ----
DUMP_FILE="$DUMP_DIR/all-databases.sql"
MYSQL_ARGS=(-u "$MYSQL_USER")
[ -n "${MYSQL_PASSWORD:-}" ] && MYSQL_ARGS+=(-p"$MYSQL_PASSWORD")

DUMP_OK=1
if ! mysqldump "${MYSQL_ARGS[@]}" \
        --all-databases --single-transaction --quick --routines --triggers --events \
        > "$DUMP_FILE.tmp" 2>"$DUMP_DIR/mysqldump.err"; then
    echo "ERROR: mysqldump failed:"
    cat "$DUMP_DIR/mysqldump.err"
    DUMP_OK=0
else
    mv "$DUMP_FILE.tmp" "$DUMP_FILE"
    echo "  DB dump OK: $(du -h "$DUMP_FILE" | cut -f1)"
fi

# ---- build the backup target list ----
BACKUP_TARGETS=("$WEBROOT")
if [ -d "$LSWS_CONF_DIR" ]; then
    BACKUP_TARGETS+=("$LSWS_CONF_DIR")
else
    echo "  NOTE: $LSWS_CONF_DIR not found, skipping (OpenLiteSpeed installed elsewhere?)"
fi
if [ "$DUMP_OK" -eq 1 ]; then
    BACKUP_TARGETS+=("$DUMP_FILE")
else
    echo "  Continuing with file backup despite the dump failure -- the run"
    echo "  will still be reported as FAILED so this doesn't go unnoticed."
fi

# ---- backup ----
echo "Uploading to ${RESTIC_REPOSITORY}..."
if restic backup "${BACKUP_TARGETS[@]}" --exclude-file="$EXCLUDE_FILE" --pack-size 64; then
    BACKUP_OK=1
else
    BACKUP_OK=0
fi

FORGET_OK=1
if [ "$BACKUP_OK" -eq 1 ]; then
    # shellcheck disable=SC2086
    restic forget $RETENTION --prune || FORGET_OK=0
fi

# ---- publish log to the remote (best-effort) ----
# NOTE: unlike gdrive, this is an S3-compatible remote -- the first path
# segment is the BUCKET, so this has to include it explicitly rather than
# hardcoding "Backup_CloudVPS/..." the way the Docker fleet's script does.
if [ "$UPLOAD_LOG" = "true" ]; then
    LOG_BUCKET="${RCLONE_PATH%%/*}"
    rclone copyto "$LOGFILE" "${RCLONE_REMOTE}:${LOG_BUCKET}/Backup_CloudVPS/_logs/${HOST_LABEL}.log" 2>/dev/null || true
fi

# ---- report ----
if [ "$BACKUP_OK" -eq 1 ] && [ "$FORGET_OK" -eq 1 ] && [ "$DUMP_OK" -eq 1 ]; then
    echo "Backup finished at $(date)."
    SUMMARY="Backup OK at $(date '+%F %H:%M')."
    [ "$PUSHOVER_NOTIFY_SUCCESS" = "true" ] && send_alert "SUCCESS" "$SUMMARY"
    [ -n "$KUMA_PUSH_URL" ] && curl -fsS -m 10 -G "$KUMA_PUSH_URL" --data-urlencode "status=up" --data-urlencode "msg=OK" >/dev/null
    exit 0
else
    LOG_TAIL=$(tail -n 5 "$LOGFILE" 2>/dev/null | cut -c1-800)
    send_alert "FAILED" "Backup failed on ${HOST_LABEL}. Full log: ${LOGFILE}. Last lines: ${LOG_TAIL}"
    send_failure_email
    [ -n "$KUMA_PUSH_URL" ] && curl -fsS -m 10 -G "$KUMA_PUSH_URL" --data-urlencode "status=down" --data-urlencode "msg=dump, backup, or forget failed" >/dev/null
    exit 1
fi
