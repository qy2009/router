#!/bin/sh

# ─────────────────────────────────────────────
#  Weekly Router Backup to SD Card
#  GL.iNet X3000 — OpenWrt
# ─────────────────────────────────────────────

BACKUP_DIR="/mnt/sdcard/router-backups"
DATE=$(date +"%Y-%m-%d_%H%M")
LOGFILE="/tmp/backup-last.log"

log() { echo "[$DATE] $1" | tee -a "$LOGFILE"; }

# ── 1. Make sure SD card is mounted ──────────
SD_DEV="/dev/sda1"
SD_MOUNT="/mnt/sdcard"

if ! mountpoint -q "$SD_MOUNT"; then
    mkdir -p "$SD_MOUNT"
    mount "$SD_DEV" "$SD_MOUNT" 2>/dev/null
    if [ $? -ne 0 ]; then
        log "ERROR: Cannot mount SD card at $SD_DEV. Aborting."
        exit 1
    fi
    log "SD card mounted at $SD_MOUNT"
fi

mkdir -p "$BACKUP_DIR"

# ── 2. sysupgrade config backup ──────────────
SYSUP_FILE="$BACKUP_DIR/sysupgrade_${DATE}.tar.gz"
sysupgrade -b "$SYSUP_FILE"
log "sysupgrade backup: $SYSUP_FILE"

# ── 3. OpenClash full backup ──────────────────
OC_FILE="$BACKUP_DIR/openclash_${DATE}.tar.gz"
tar -czf "$OC_FILE" /etc/openclash/ /etc/config/openclash 2>/dev/null
log "OpenClash backup: $OC_FILE"

# ── 4. Installed package list ─────────────────
PKG_FILE="$BACKUP_DIR/packages_${DATE}.txt"
opkg list-installed > "$PKG_FILE"
log "Package list: $PKG_FILE"

# ── 5. Rotate old backups (keep last 8 weeks) ─
for pattern in "sysupgrade_" "openclash_" "packages_"; do
    ls -t "$BACKUP_DIR/${pattern}"* 2>/dev/null | tail -n +9 | xargs rm -f 2>/dev/null
done
log "Old backups rotated (keeping 8 most recent each)"

log "Backup complete."
