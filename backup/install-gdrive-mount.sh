#!/bin/bash
# install-gdrive-mount.sh — mount Google Drive at /gdrive on Debian,
# on-demand, surviving reboots via systemd.
#
# Prereq: rclone remote already configured (same rclone.conf you copy to
# every VPS). Usage:
#   bash install-gdrive-mount.sh            # mounts remote "gdrive" at /gdrive
#   bash install-gdrive-mount.sh mydrive    # different remote name
#
# Manage afterwards:
#   systemctl status rclone-gdrive     # is it mounted?
#   systemctl stop rclone-gdrive       # unmount
#   systemctl disable rclone-gdrive    # stop auto-mounting at boot

set -e
REMOTE="${1:-gdrive}"
MOUNTPOINT="/gdrive"

[ "$EUID" -eq 0 ] || { echo "Run as root."; exit 1; }

echo "[+] Installing dependencies..."
apt-get update -qq
apt-get install -y fuse3
command -v rclone >/dev/null 2>&1 || curl -s https://rclone.org/install.sh | bash

rclone listremotes | grep -q "^${REMOTE}:" || {
    echo "[x] rclone remote '${REMOTE}:' not found. Copy your rclone.conf to"
    echo "    /root/.config/rclone/rclone.conf first."
    exit 1
}

# Needed for --allow-other (so non-root processes/containers can read the mount)
grep -q '^user_allow_other' /etc/fuse.conf || echo 'user_allow_other' >> /etc/fuse.conf

mkdir -p "$MOUNTPOINT"

echo "[+] Creating systemd unit..."
cat > /etc/systemd/system/rclone-gdrive.service <<EOF
[Unit]
Description=rclone mount ${REMOTE}: at ${MOUNTPOINT}
Wants=network-online.target
After=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/rclone mount ${REMOTE}: ${MOUNTPOINT} \\
  --allow-other \\
  --vfs-cache-mode writes \\
  --vfs-cache-max-size 1G \\
  --vfs-cache-max-age 12h \\
  --dir-cache-time 30m \\
  --poll-interval 1m \\
  --umask 022 \\
  --log-file /var/log/rclone-gdrive.log \\
  --log-level NOTICE
ExecStop=/bin/fusermount3 -uz ${MOUNTPOINT}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
# --vfs-cache-mode writes: buffers writes locally before upload — needed
#   for apps that expect normal file semantics (seek-on-write etc). Cache
#   capped at 1G on purpose: your free-tier VPS disks are small.
# NOT using --vfs-cache-mode full: it caches reads too and can quietly eat
#   the disk on a 47GB boot volume.

systemctl daemon-reload
systemctl enable --now rclone-gdrive

sleep 3
if mountpoint -q "$MOUNTPOINT"; then
    echo "[+] Mounted: ${REMOTE}: -> ${MOUNTPOINT}"
    ls "$MOUNTPOINT" | head -5
else
    echo "[!] Mount not ready yet — check: systemctl status rclone-gdrive"
fi

cat <<'EOF'

NOTE for backup-agent.sh hosts: /gdrive is a window onto the SAME Google
Drive the backups go to — do not point the backup at /gdrive (it would
back Drive up into itself) and keep /gdrive out of $DATA_DIR. The default
excludes already avoid this as long as /gdrive stays at the filesystem
root, outside /data and /root.
EOF
