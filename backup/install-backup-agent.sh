#!/bin/bash
# install-backup-agent.sh — run once on a freshly provisioned VPS, right
# after your existing vps-setup.sh (SSH hardening / fail2ban / BBR / swap).
#
# What this deliberately does NOT do: authenticate rclone to Google Drive
# interactively. Set up ONE rclone remote using a Google service account
# (ideally with domain-wide delegation, since these are Workspace/EDU
# accounts — see Backup-Architecture.md, leg 1) a single time, then copy
# that same rclone.conf to every VPS. No per-machine OAuth browser dance,
# no token expiry surprises on a headless box.
#
# Usage, on the new VPS (after your vps-setup.sh):
#   git clone https://github.com/you/router.git && cd router/backup
#   bash install-backup-agent.sh              # confirms hostname + Drive path
#   # -> prompts for the age passphrase to unlock secrets-bundle.tar.age,
#   #    which contains rclone.conf, secrets.env, and ssmtp.conf together.
#   # No rclone.conf pre-copy step needed if the bundle is in the repo.

set -e
HOST_LABEL="${1:-$(hostname)}"   # defaults to this VPS's hostname
GDRIVE_PATH="Backup_CloudVPS/${HOST_LABEL}"

echo "============================================================"
echo "  Backup agent will be configured as:"
echo "    Host label:   ${HOST_LABEL}"
echo "    Drive folder: gdrive:${GDRIVE_PATH}"
echo "    Schedule:     weekly, Sundays 03:00"
echo "============================================================"
read -r -p "Proceed? [y/N] " CONFIRM
[ "$CONFIRM" = "y" ] || { echo "Aborted. Re-run with a label: install-backup-agent.sh <host-label>"; exit 1; }

echo "[+] Installing restic/rclone/curl (never touching an existing docker install)..."
apt-get update -qq
command -v restic >/dev/null 2>&1 || apt-get install -y restic
command -v curl >/dev/null 2>&1 || apt-get install -y curl
if ! command -v docker >/dev/null 2>&1; then
    apt-get install -y docker.io
else
    echo "    docker already present ($(docker --version)) — leaving it alone."
fi
restic self-update || true   # apt's restic is often behind; this is a no-op if already current

# rclone: try apt first — more reliable than the rclone.org curl|bash installer
# on some Oracle free-tier VPS networks (seen hanging on sjc-tool).
if ! command -v rclone >/dev/null 2>&1; then
    apt-get install -y rclone || curl -s https://rclone.org/install.sh | bash
fi

# ---- credential bootstrap: decrypt the age bundle if it's sitting here ----
if [ -f secrets-bundle.tar.age ]; then
    command -v age >/dev/null 2>&1 || apt-get install -y age >/dev/null
    echo "[+] Found secrets-bundle.tar.age — decrypting (rclone.conf, secrets.env, ssmtp.conf)."
    BSTAGE=$(mktemp -d)
    age -d -o "$BSTAGE/bundle.tar" secrets-bundle.tar.age
    tar -C "$BSTAGE" -xf "$BSTAGE/bundle.tar"
    mkdir -p /root/.config/rclone /etc/backup-agent /etc/ssmtp
    [ -f "$BSTAGE/rclone.conf" ] && install -m 600 "$BSTAGE/rclone.conf" /root/.config/rclone/rclone.conf
    [ -f "$BSTAGE/secrets.env" ] && install -m 600 "$BSTAGE/secrets.env" /etc/backup-agent/secrets.env
    [ -f "$BSTAGE/ssmtp.conf" ]  && install -m 600 "$BSTAGE/ssmtp.conf"  /etc/ssmtp/ssmtp.conf
    rm -rf "$BSTAGE"
    echo "[+] Credentials installed from bundle."
fi

if [ ! -f /root/.config/rclone/rclone.conf ]; then
    echo "[x] No rclone.conf at /root/.config/rclone/rclone.conf, and no"
    echo "    secrets-bundle.tar.age found alongside this script. Either"
    echo "    copy rclone.conf here directly, or put the bundle next to"
    echo "    this script (see make-secrets-bundle.sh), then re-run."
    exit 1
fi

echo "[+] Laying down config/secrets skeleton..."
mkdir -p /etc/backup-agent
touch /etc/backup-agent/excludes.txt
chmod 700 /etc/backup-agent

if [ -f system-files.txt ] && [ ! -f /etc/backup-agent/system-files.txt ]; then
    cp system-files.txt /etc/backup-agent/system-files.txt
    echo "[+] Installed /etc/backup-agent/system-files.txt (review it — it assumes"
    echo "    ssmtp/fail2ban/BBR sysctl paths from your vps-setup.sh; adjust if yours differ)."
fi

if [ ! -f /etc/backup-agent/secrets.env ]; then
    cat > /etc/backup-agent/secrets.env <<'EOF'
export RESTIC_PASSWORD="CHANGE_ME"
PUSHOVER_USER="CHANGE_ME"
PUSHOVER_TOKEN="CHANGE_ME"
EOF
    chmod 600 /etc/backup-agent/secrets.env
    echo "[!] Edit /etc/backup-agent/secrets.env with real values before the first run."
fi

if [ ! -f /etc/backup-agent.conf ]; then
    cat > /etc/backup-agent.conf <<EOF
HOST_LABEL="${HOST_LABEL}"
GDRIVE_PATH="${GDRIVE_PATH}"
KUMA_PUSH_URL=""
EOF
    echo "[!] Edit /etc/backup-agent.conf and set KUMA_PUSH_URL once you've"
    echo "    created that VPS's Push monitor in Uptime Kuma."
fi

install -m 700 backup-agent.sh /usr/local/bin/backup-agent.sh

echo "[+] Checking / initializing the restic repository..."
# shellcheck disable=SC1091
source /etc/backup-agent.conf
# shellcheck disable=SC1091
source /etc/backup-agent/secrets.env
export RESTIC_REPOSITORY="rclone:gdrive:${GDRIVE_PATH}"
if ! restic snapshots >/dev/null 2>&1; then
    echo "    No existing repo found at gdrive:${GDRIVE_PATH} — initializing."
    restic init
fi

echo "[+] Scheduling weekly cron (Sundays 03:00)..."
( crontab -l 2>/dev/null | grep -v backup-agent.sh || true; echo "0 3 * * 0 /usr/local/bin/backup-agent.sh" ) | crontab -

cat <<EOF

============================================================
  backup-agent installed: ${HOST_LABEL}
============================================================
  Before the first real run:
    1. /etc/backup-agent/secrets.env   — real RESTIC_PASSWORD / Pushover creds
    2. /etc/backup-agent.conf          — KUMA_PUSH_URL for this VPS
    3. /etc/backup-agent/excludes.txt  — anything you don't want backed up

  Test it now rather than waiting for Sunday:
    /usr/local/bin/backup-agent.sh
    tail -n 50 /var/log/backup-agent.log
============================================================
EOF
