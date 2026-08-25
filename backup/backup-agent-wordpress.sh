#!/bin/bash
# Native OpenLiteSpeed + WordPress + MariaDB backup agent.
# Uses a transactional SQL dump instead of copying the live MariaDB datadir.

set -uo pipefail

LOCKFILE="/var/run/backup-agent.lock"
exec 9>"$LOCKFILE"
flock -n 9 || { echo "Backup already running — exiting."; exit 1; }

HOST_LABEL="$(hostname)"
WEBROOT="/var/www"
LSWS_CONF_DIR="/usr/local/lsws/conf"
ACME_DIR="/root/.acme.sh"
DUMP_DIR="/var/backups/mysql-dumps"
LOGFILE="/var/log/backup-agent.log"
EXCLUDE_FILE="/etc/backup-agent/excludes.txt"
SECRETS_FILE="/etc/backup-agent/secrets.env"
RCLONE_REMOTE="oracle"
RCLONE_PATH=""
UPLOAD_LOG=true
RETENTION="--keep-weekly 8 --keep-monthly 6 --keep-yearly 2"
KUMA_PUSH_URL=""
KUMA_PUSH_RETRIES=9
KUMA_PUSH_RETRY_DELAY=10
PUSHOVER_NOTIFY_SUCCESS=true
EMAIL_RECIPIENT=""
MYSQL_USER="root"

CONF="/etc/backup-agent.conf"
[ -f "$CONF" ] && source "$CONF"

if [ -z "$RCLONE_PATH" ]; then
    RCLONE_PATH="vps-backups/Backup_CloudVPS/${HOST_LABEL}"
fi
export RESTIC_REPOSITORY="rclone:${RCLONE_REMOTE}:${RCLONE_PATH}"

if [ -f "$SECRETS_FILE" ]; then
    source "$SECRETS_FILE"
else
    echo "Missing $SECRETS_FILE — aborting." >&2
    exit 1
fi

mkdir -p "$(dirname "$LOGFILE")" "$DUMP_DIR" "$(dirname "$EXCLUDE_FILE")"
[ -f "$EXCLUDE_FILE" ] || touch "$EXCLUDE_FILE"
exec >>"$LOGFILE" 2>&1
echo "===== [$HOST_LABEL] Backup run started: $(date) ====="

send_alert() {
    local STATUS=$1 MSG=$2
    [ -n "${PUSHOVER_TOKEN:-}" ] && curl -s \
        --form-string "token=$PUSHOVER_TOKEN" \
        --form-string "user=$PUSHOVER_USER" \
        --form-string "title=${HOST_LABEL} Backup $STATUS" \
        --form-string "message=$MSG" \
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

push_kuma() {
    local STATUS=$1 MSG=$2 attempt
    [ -z "$KUMA_PUSH_URL" ] && return 0
    for ((attempt=1; attempt<=KUMA_PUSH_RETRIES; attempt++)); do
        if curl -fsS -m 10 -G "$KUMA_PUSH_URL" \
            --data-urlencode "status=$STATUS" \
            --data-urlencode "msg=$MSG" >/dev/null; then
            echo "Kuma heartbeat delivered on attempt ${attempt}."
            return 0
        fi
        if [ "$attempt" -lt "$KUMA_PUSH_RETRIES" ]; then
            echo "Kuma heartbeat attempt ${attempt}/${KUMA_PUSH_RETRIES} failed; retrying in ${KUMA_PUSH_RETRY_DELAY}s."
            sleep "$KUMA_PUSH_RETRY_DELAY"
        fi
    done
    echo "WARNING: Kuma heartbeat failed after ${KUMA_PUSH_RETRIES} attempts."
    return 1
}

fail_run() {
    local MESSAGE=$1
    echo "ERROR: $MESSAGE"
    send_alert "FAILED" "$MESSAGE"
    send_failure_email
    push_kuma down "$MESSAGE" || true
    exit 1
}

# Do not silently initialize a replacement when a repository disappears. That
# would hide the loss of snapshot history; installation is the only place that
# may create a repository.
if ! restic cat config >/dev/null 2>&1; then
    fail_run "Restic repository missing or inaccessible: ${RESTIC_REPOSITORY}"
fi

command -v mysqldump >/dev/null 2>&1 || fail_run "mysqldump is not installed"
[ -d "$WEBROOT" ] || fail_run "WordPress web root is missing: ${WEBROOT}"

DUMP_FILE="$DUMP_DIR/all-databases.sql"
MYSQL_ARGS=(-u "$MYSQL_USER")
[ -n "${MYSQL_PASSWORD:-}" ] && MYSQL_ARGS+=(-p"$MYSQL_PASSWORD")

DUMP_OK=1
if ! mysqldump "${MYSQL_ARGS[@]}" \
        --all-databases --single-transaction --quick --routines --triggers --events \
        > "$DUMP_FILE.tmp" 2>"$DUMP_DIR/mysqldump.err"; then
    echo "ERROR: mysqldump failed:"
    cat "$DUMP_DIR/mysqldump.err"
    rm -f "$DUMP_FILE.tmp"
    DUMP_OK=0
else
    mv "$DUMP_FILE.tmp" "$DUMP_FILE"
    echo "DB dump OK: $(du -h "$DUMP_FILE" | cut -f1)"
fi

BACKUP_TARGETS=("$WEBROOT")
for path in \
    "$LSWS_CONF_DIR" \
    "$ACME_DIR" \
    "$DUMP_FILE" \
    /etc/mysql \
    /etc/backup-agent.conf \
    /etc/backup-agent/excludes.txt \
    /etc/ssh/sshd_config \
    /var/spool/cron/crontabs/root; do
    [ -e "$path" ] && BACKUP_TARGETS+=("$path")
done

echo "Backup targets:"
printf '  %s\n' "${BACKUP_TARGETS[@]}"

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

if [ "$UPLOAD_LOG" = "true" ]; then
    LOG_BUCKET="${RCLONE_PATH%%/*}"
    rclone copyto "$LOGFILE" \
        "${RCLONE_REMOTE}:${LOG_BUCKET}/Backup_CloudVPS/_logs/${HOST_LABEL}.log" \
        2>/dev/null || true
fi

if [ "$BACKUP_OK" -eq 1 ] && [ "$FORGET_OK" -eq 1 ] && [ "$DUMP_OK" -eq 1 ]; then
    echo "Backup finished at $(date)."
    SUMMARY="Backup OK at $(date '+%F %H:%M')."
    [ "$PUSHOVER_NOTIFY_SUCCESS" = "true" ] && send_alert "SUCCESS" "$SUMMARY"
    push_kuma up OK || true
    exit 0
fi

fail_run "WordPress dump, Restic backup, or retention cleanup failed on ${HOST_LABEL}"

