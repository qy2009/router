#!/bin/bash
# install-backup-agent-wordpress.sh — run once on a native (non-Docker)
# OpenLiteSpeed + WordPress + MariaDB VPS. Sibling to install-backup-agent.sh
# (the Docker-fleet installer) — same secrets-bundle bootstrap, same cron
# pattern, but installs backup-agent-wordpress.sh instead, and the backend
# is the "oracle" rclone remote (Oracle Object Storage, S3-compatible) that
# already lives in the shared rclone.conf — no new credentials to set up,
# just a dedicated bucket (created below if it doesn't exist yet).
#
# Usage, on the WordPress VPS:
#   git clone https://github.com/qy2009/router.git && cd router/backup
#   bash install-backup-agent-wordpress.sh
#   # -> prompts for the age passphrase to unlock secrets-bundle.tar.age
#   #    (same bundle/passphrase as the rest of the fleet: rclone.conf,
#   #    secrets.env, ssmtp.conf — rclone.conf already has "oracle" in it).

set -e
HOST_LABEL="${1:-$(hostname)}"
RCLONE_BUCKET="vps-backups"
RCLONE_PATH="${RCLONE_BUCKET}/Backup_CloudVPS/${HOST_LABEL}"

echo "============================================================"
echo "  WordPress backup agent will be configured as:"
echo "    Host label:      ${HOST_LABEL}"
echo "    Backend folder:  oracle:${RCLONE_PATH}"
echo "    Schedule:        weekly, Sundays 03:00"
echo "============================================================"
read -r -p "Proceed? [y/N] " CONFIRM
[ "$CONFIRM" = "y" ] || { echo "Aborted. Re-run with a label: install-backup-agent-wordpress.sh <host-label>"; exit 1; }

echo "[+] Installing restic/rclone/curl/mariadb-client..."
apt-get update -qq
command -v restic >/dev/null 2>&1 || apt-get install -y restic
command -v curl >/dev/null 2>&1 || apt-get install -y curl
command -v mysqldump >/dev/null 2>&1 || apt-get install -y mariadb-client
restic self-update || true

if ! command -v rclone >/dev/null 2>&1; then
    apt-get install -y rclone || curl -s https://rclone.org/install.sh | bash
fi

# ---- credential bootstrap: decrypt the age bundle if it's sitting here ----
# Same bundle as the Docker fleet -- it carries RESTIC_PASSWORD, Pushover
# creds, ssmtp.conf, AND rclone.conf with the "oracle" remote already in it
# (gdrive is in there too, harmless here, just unused).
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

# ---- confirm the "oracle" remote made it in, and the bucket exists ----
if ! rclone listremotes --config /root/.config/rclone/rclone.conf 2>/dev/null | grep -q '^oracle:'; then
    echo "[x] No 'oracle' remote in the decrypted rclone.conf. This script expects"
    echo "    the shared secrets-bundle.tar.age (which already has one). If you're"
    echo "    bootstrapping from a hand-copied rclone.conf instead, add an 'oracle'"
    echo "    remote (S3-compatible, Oracle Object Storage) before continuing."
    exit 1
fi
if ! rclone lsd "oracle:${RCLONE_BUCKET}" >/dev/null 2>&1; then
    echo "[+] Bucket '${RCLONE_BUCKET}' doesn't exist yet on Oracle Object Storage — creating it."
    rclone mkdir "oracle:${RCLONE_BUCKET}"
fi

echo "[+] Laying down config/secrets skeleton..."
mkdir -p /etc/backup-agent
if [ ! -f /etc/backup-agent/excludes.txt ]; then
    cat > /etc/backup-agent/excludes.txt << 'EOF'
# Redundant with the separate GitHub backup leg -- this clone is already
# versioned on GitHub, no need to re-back-it-up from every VPS every week.
/root/router

# Common WordPress cache/churn paths -- regenerable, not worth the space.
# Uncomment/add to these if a caching plugin creates others.
/var/www/*/wp-content/cache
/var/www/*/wp-content/uploads/cache
/var/www/*/wp-content/litespeed/cache
EOF
fi
chmod 700 /etc/backup-agent

if [ ! -f /etc/backup-agent/secrets.env ]; then
    cat > /etc/backup-agent/secrets.env <<'EOF'
export RESTIC_PASSWORD="CHANGE_ME"
PUSHOVER_USER="CHANGE_ME"
PUSHOVER_TOKEN="CHANGE_ME"
# Only needed if you later lock down MariaDB root with a real password:
# MYSQL_PASSWORD="CHANGE_ME"
EOF
    chmod 600 /etc/backup-agent/secrets.env
    echo "[!] Edit /etc/backup-agent/secrets.env with real values before the first run."
else
    echo "    /etc/backup-agent/secrets.env already present (from the bundle) — reusing it."
fi

if [ ! -f /etc/backup-agent.conf ]; then
    cat > /etc/backup-agent.conf <<EOF
HOST_LABEL="${HOST_LABEL}"
RCLONE_REMOTE="oracle"
RCLONE_PATH="${RCLONE_PATH}"
KUMA_PUSH_URL=""

# Only read by restore-agent-wordpress.sh, and only when restoring onto a
# bare box (no OpenLiteSpeed installed yet). Not secret -- just the site's
# real domain/email/DB name so ols1clk.sh has something to run with. The
# OLS admin panel password and ols1clk's scratch DB password are generated
# randomly at restore time instead of stored here -- see restore-agent-wordpress.sh.
WP_DOMAIN="CHANGE_ME"
WP_EMAIL="CHANGE_ME"
WP_DB_NAME="CHANGE_ME"
WP_DB_USER="CHANGE_ME"
EOF
    echo "[!] Edit /etc/backup-agent.conf and set KUMA_PUSH_URL once you've"
    echo "    created this VPS's Push monitor in Uptime Kuma."
fi

install -m 700 backup-agent-wordpress.sh /usr/local/bin/backup-agent.sh

echo "[+] Checking / initializing the restic repository..."
# shellcheck disable=SC1091
source /etc/backup-agent.conf
# shellcheck disable=SC1091
source /etc/backup-agent/secrets.env
export RESTIC_REPOSITORY="rclone:${RCLONE_REMOTE:-oracle}:${RCLONE_PATH}"
if ! restic snapshots >/dev/null 2>&1; then
    echo "    No existing repo found at ${RESTIC_REPOSITORY} — initializing."
    restic init
fi

echo "[+] Scheduling weekly cron (Sundays 03:00)..."
( crontab -l 2>/dev/null | grep -v backup-agent.sh || true; echo "0 3 * * 0 /usr/local/bin/backup-agent.sh" ) | crontab -

cat <<EOF

============================================================
  WordPress backup-agent installed: ${HOST_LABEL}
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
