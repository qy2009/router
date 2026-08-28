#!/bin/sh

# Weekly GL.iNet X3000 backup to the attached SD card.
# Notifications are loaded from /etc/router-backup-notify.env (mode 600).

set -u

PATH=/usr/sbin:/usr/bin:/sbin:/bin
SD_DEVICE="/dev/sda1"
SD_FALLBACK_MOUNT="/mnt/sda1"
KEEP_COUNT=8
LOCK_FILE="/tmp/router-backup.lock"
TMP_LOG="/tmp/backup-last.log"
NOTIFY_ENV="/etc/router-backup-notify.env"
HOST_LABEL="home-router"

PERSIST_LOG=""
SYSUP_TMP=""
OPENCLASH_TMP=""
PKG_TMP=""

[ -r "$NOTIFY_ENV" ] && . "$NOTIFY_ENV"

: "${PUSHOVER_USER:=}"
: "${PUSHOVER_TOKEN:=}"
: "${UPTIME_PUSH_URL:=}"
: "${PUSHOVER_NOTIFY_SUCCESS:=1}"

DATE="$(date '+%Y-%m-%d_%H%M%S')"
: > "$TMP_LOG"

log() {
    message="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    printf '%s\n' "$message" | tee -a "$TMP_LOG"
    [ -n "$PERSIST_LOG" ] && printf '%s\n' "$message" >> "$PERSIST_LOG"
    logger -t router-backup "$*" 2>/dev/null || true
}

pushover() {
    level="$1"
    text="$2"
    [ -n "$PUSHOVER_USER" ] || return 0
    [ -n "$PUSHOVER_TOKEN" ] || return 0
    curl -fsS --connect-timeout 10 --max-time 30 \
        --form-string "token=$PUSHOVER_TOKEN" \
        --form-string "user=$PUSHOVER_USER" \
        --form-string "title=$HOST_LABEL backup: $level" \
        --form-string "message=$text" \
        https://api.pushover.net/1/messages.json >/dev/null 2>&1 || {
            log "WARNING: Pushover notification failed"
            return 0
        }
}

uptime_push() {
    state="$1"
    text="$2"
    [ -n "$UPTIME_PUSH_URL" ] || return 0
    response="$(curl -fsS --connect-timeout 10 --max-time 30 --get \
        --data-urlencode "status=$state" \
        --data-urlencode "msg=$text" \
        --data-urlencode "ping=" \
        "$UPTIME_PUSH_URL" 2>/dev/null)" || response=""
    case "$response" in
        *'"ok":true'*) return 0 ;;
        *) log "WARNING: Uptime Kuma heartbeat failed" ;;
    esac
    return 0
}

fail() {
    reason="$*"
    log "ERROR: $reason"
    uptime_push down "$reason"
    pushover FAILED "$reason"
    exit 1
}

cleanup() {
    [ -n "$SYSUP_TMP" ] && rm -f "$SYSUP_TMP"
    [ -n "$OPENCLASH_TMP" ] && rm -f "$OPENCLASH_TMP"
    [ -n "$PKG_TMP" ] && rm -f "$PKG_TMP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

exec 9>"$LOCK_FILE"
flock -n 9 || {
    log "Another backup is already running; exiting"
    exit 0
}

find_mount() {
    awk -v device="$SD_DEVICE" '$1 == device { print $2; exit }' /proc/mounts
}

SD_MOUNT="$(find_mount)"
if [ -z "$SD_MOUNT" ]; then
    mkdir -p "$SD_FALLBACK_MOUNT" || fail "Cannot create $SD_FALLBACK_MOUNT"
    mount "$SD_DEVICE" "$SD_FALLBACK_MOUNT" >/dev/null 2>&1 || \
        fail "Cannot mount $SD_DEVICE at $SD_FALLBACK_MOUNT"
    SD_MOUNT="$SD_FALLBACK_MOUNT"
fi

BACKUP_DIR="$SD_MOUNT/router-backups"
mkdir -p "$BACKUP_DIR" || fail "Cannot create $BACKUP_DIR"
PERSIST_LOG="$BACKUP_DIR/backup-history.log"

WRITE_TEST="$BACKUP_DIR/.write-test.$$"
: > "$WRITE_TEST" 2>/dev/null || fail "SD card is not writable at $BACKUP_DIR"
rm -f "$WRITE_TEST"

log "Backup started on $SD_DEVICE mounted at $SD_MOUNT"

SYSUP_FILE="$BACKUP_DIR/sysupgrade_${DATE}.tar.gz"
SYSUP_TMP="$SYSUP_FILE.part"
sysupgrade -b "$SYSUP_TMP" >/dev/null 2>&1 || fail "sysupgrade configuration backup failed"
[ -s "$SYSUP_TMP" ] || fail "sysupgrade configuration backup is empty"
mv "$SYSUP_TMP" "$SYSUP_FILE" || fail "Cannot finalize sysupgrade backup"
SYSUP_TMP=""
sha256sum "$SYSUP_FILE" > "$SYSUP_FILE.sha256" 2>/dev/null || true
log "Created $(basename "$SYSUP_FILE") ($(du -h "$SYSUP_FILE" | awk '{print $1}'))"

OPENCLASH_FILE="$BACKUP_DIR/openclash-config_${DATE}.tar.gz"
OPENCLASH_TMP="$OPENCLASH_FILE.part"
tar -C / -czf "$OPENCLASH_TMP" \
    etc/config/openclash \
    etc/openclash/config \
    etc/openclash/custom \
    etc/openclash/overwrite \
    etc/openclash/proxy_provider \
    etc/openclash/rule_provider 2>/dev/null || \
    fail "OpenClash configuration backup failed"
[ -s "$OPENCLASH_TMP" ] || fail "OpenClash configuration backup is empty"
mv "$OPENCLASH_TMP" "$OPENCLASH_FILE" || fail "Cannot finalize OpenClash backup"
OPENCLASH_TMP=""
sha256sum "$OPENCLASH_FILE" > "$OPENCLASH_FILE.sha256" 2>/dev/null || true
log "Created $(basename "$OPENCLASH_FILE") ($(du -h "$OPENCLASH_FILE" | awk '{print $1}'))"

PKG_FILE="$BACKUP_DIR/packages_${DATE}.txt"
PKG_TMP="$PKG_FILE.part"
opkg list-installed > "$PKG_TMP" 2>/dev/null || fail "Installed package inventory failed"
[ -s "$PKG_TMP" ] || fail "Installed package inventory is empty"
mv "$PKG_TMP" "$PKG_FILE" || fail "Cannot finalize package inventory"
PKG_TMP=""
sha256sum "$PKG_FILE" > "$PKG_FILE.sha256" 2>/dev/null || true
log "Created $(basename "$PKG_FILE")"

rotate_pattern() {
    pattern="$1"
    ls -1t $pattern 2>/dev/null | sed -n "$((KEEP_COUNT + 1)),\$p" | while IFS= read -r old_file; do
        [ -n "$old_file" ] || continue
        rm -f "$old_file" "$old_file.sha256"
        log "Removed expired backup $(basename "$old_file")"
    done
}

rotate_pattern "$BACKUP_DIR/sysupgrade_*.tar.gz"
rotate_pattern "$BACKUP_DIR/openclash-config_*.tar.gz"
rotate_pattern "$BACKUP_DIR/packages_*.txt"

SUMMARY="Backup completed: $(basename "$SYSUP_FILE"), $(basename "$OPENCLASH_FILE"), $(basename "$PKG_FILE")"
log "$SUMMARY"
uptime_push up "$SUMMARY"
[ "$PUSHOVER_NOTIFY_SUCCESS" = "1" ] && pushover SUCCESS "$SUMMARY"

exit 0

