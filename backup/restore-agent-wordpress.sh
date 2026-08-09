#!/bin/bash
# restore-agent-wordpress.sh — automated recovery companion to
# backup-agent-wordpress.sh, for native (non-Docker) OpenLiteSpeed +
# WordPress + MariaDB boxes.
#
# Sibling to restore-agent.sh (the Docker-fleet version). Same
# secrets-bundle bootstrap and overall shape, but where restore-agent.sh
# just needs Docker to already be there (every app is a container), this
# one may be landing on a bare VPS with NO web stack installed at all --
# so it installs OpenLiteSpeed + PHP + MariaDB from scratch (via
# ols1clk.sh, LiteSpeed's official installer, if not already present)
# BEFORE restoring data on top of it.
#
# Run on a FRESH VPS that already has your vps-setup.sh hardening applied.
# Needs secrets-bundle.tar.age (rclone.conf + secrets.env + ssmtp.conf,
# see make-secrets-bundle.sh) sitting next to this script -- one passphrase
# unlocks all three. secrets.env must also carry OLS_ADMIN_PASSWORD and
# WP_DB_PASSWORD (see install-backup-agent-wordpress.sh's template) so this
# script never has to prompt for or hardcode a password.
#
# Usage:
#   git clone https://github.com/qy2009/router.git && cd router/backup
#   bash restore-agent-wordpress.sh xblog      # the DEAD VPS's host label

set -e
HOST_LABEL="${1:?Usage: restore-agent-wordpress.sh <host-label>   (the DEAD VPS's label -- the bucket/folder to restore FROM, not this machine's hostname)}"
WEBROOT="/var/www"

echo "[+] Installing restic/rclone/curl/mariadb-client..."
apt-get update -qq
command -v restic >/dev/null 2>&1 || apt-get install -y restic
command -v curl >/dev/null 2>&1 || apt-get install -y curl
command -v mysqldump >/dev/null 2>&1 || apt-get install -y mariadb-client
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
    echo "[+] Credentials installed from bundle — same passphrase unlocks all three files."
fi

if [ ! -f /root/.config/rclone/rclone.conf ]; then
    echo "[x] No rclone.conf, and no secrets-bundle.tar.age alongside this script."
    echo "    Copy one of the two here, then re-run."
    exit 1
fi
if ! rclone listremotes --config /root/.config/rclone/rclone.conf 2>/dev/null | grep -q '^oracle:'; then
    echo "[x] No 'oracle' remote in rclone.conf. Make sure secrets-bundle.tar.age was"
    echo "    regenerated (make-secrets-bundle.sh) after the oracle remote was added --"
    echo "    the copy on GitHub may predate it. Add the remote by hand and re-run if not."
    exit 1
fi

RCLONE_PATH="vps-backups/Backup_CloudVPS/${HOST_LABEL}"
export RESTIC_REPOSITORY="rclone:oracle:${RCLONE_PATH}"
[ -f /etc/backup-agent/secrets.env ] && source /etc/backup-agent/secrets.env
if [ -z "${RESTIC_PASSWORD:-}" ]; then
    read -r -s -p "RESTIC_PASSWORD for ${HOST_LABEL} (from your password manager): " RESTIC_PASSWORD
    echo
    export RESTIC_PASSWORD
fi

echo "[+] Snapshots available for ${HOST_LABEL}:"
restic snapshots

# ---- install the web stack from scratch if it isn't already here ----
if command -v /usr/local/lsws/bin/lswsctrl >/dev/null 2>&1; then
    echo "[+] OpenLiteSpeed already present — leaving the install alone, will just restore data over it."
else
    echo "[+] No OpenLiteSpeed found — installing via ols1clk.sh (LiteSpeed's official installer)."
    : "${WP_DOMAIN:?Set WP_DOMAIN in /etc/backup-agent.conf (the site's real domain) before restoring to a bare box}"
    : "${WP_EMAIL:?Set WP_EMAIL in /etc/backup-agent.conf before restoring to a bare box}"
    : "${OLS_ADMIN_USER:?Set OLS_ADMIN_USER in secrets.env before restoring to a bare box}"
    : "${OLS_ADMIN_PASSWORD:?Set OLS_ADMIN_PASSWORD in secrets.env before restoring to a bare box}"
    : "${WP_DB_NAME:?Set WP_DB_NAME in /etc/backup-agent.conf before restoring to a bare box}"
    : "${WP_DB_USER:?Set WP_DB_USER in /etc/backup-agent.conf before restoring to a bare box}"
    : "${WP_DB_PASSWORD:?Set WP_DB_PASSWORD in secrets.env before restoring to a bare box}"
    # These wordpress-specific values only matter for getting ols1clk through
    # its non-interactive setup -- the restic restore + DB import below
    # completely overwrite whatever WordPress install and database this step
    # creates, so they don't need to match the ORIGINAL site's values, just
    # be present and valid.
    OLSTAGE=$(mktemp -d)
    curl -o "$OLSTAGE/ols1clk.sh" https://raw.githubusercontent.com/litespeedtech/ols1clk/master/ols1clk.sh
    bash "$OLSTAGE/ols1clk.sh" \
        --adminuser "$OLS_ADMIN_USER" \
        --email "$WP_EMAIL" \
        -A "$OLS_ADMIN_PASSWORD" \
        --wordpressplus "$WP_DOMAIN" \
        --wordpresspath "${WEBROOT}/${WP_DOMAIN}/" \
        --dbname "$WP_DB_NAME" \
        --wpuser "$WP_DB_USER" \
        --wppassword "$WP_DB_PASSWORD"
    rm -rf "$OLSTAGE"
fi

read -r -p "Restore latest snapshot to / on THIS machine? [y/N] " CONFIRM
[ "$CONFIRM" = "y" ] || { echo "Aborted — nothing changed."; exit 1; }

echo "[+] Stopping OpenLiteSpeed while data is restored underneath it..."
/usr/local/lsws/bin/lswsctrl stop || true

echo "[+] Restoring..."
restic restore latest --target /
# /var/www, /usr/local/lsws/conf/vhosts, /root/.acme.sh, and the DB dump all
# land back at their original absolute paths -- restic preserves the exact
# path, which is what makes this a one-shot restore instead of a manual
# "which file goes where" exercise. This OVERWRITES whatever ols1clk.sh
# created above, which is the point.

echo "[+] Fixing ownership on the restored web root (restic preserves the"
echo "    original uid/gid, which can drift on a cross-host restore)..."
for site in "$WEBROOT"/*/; do
    [ -d "$site" ] && chown -R www-data:www-data "$site"
done

echo "[+] Importing the database dump..."
DUMP_FILE="/var/backups/mysql-dumps/all-databases.sql"
if [ -f "$DUMP_FILE" ]; then
    MYSQL_ARGS=(-u root)
    [ -n "${MYSQL_PASSWORD:-}" ] && MYSQL_ARGS+=(-p"$MYSQL_PASSWORD")
    mysql "${MYSQL_ARGS[@]}" < "$DUMP_FILE"
    echo "    Imported $(du -h "$DUMP_FILE" | cut -f1)."
else
    echo "    WARNING: $DUMP_FILE not found in the restored snapshot — no DB restored."
fi

echo "[+] Starting OpenLiteSpeed and MariaDB..."
systemctl restart mariadb
/usr/local/lsws/bin/lswsctrl start

echo "[+] Re-arming the weekly backup cron for this host..."
if [ -f backup-agent-wordpress.sh ]; then
    install -m 700 backup-agent-wordpress.sh /usr/local/bin/backup-agent.sh
    ( crontab -l 2>/dev/null | grep -v backup-agent.sh || true; echo "0 3 * * 0 /usr/local/bin/backup-agent.sh" ) | crontab -
else
    echo "    (backup-agent-wordpress.sh not found alongside this script — copy it over"
    echo "     and re-run install-backup-agent-wordpress.sh ${HOST_LABEL} to re-arm the cron.)"
fi

if [ -f /etc/backup-agent/secrets.env ]; then
    source /etc/backup-agent/secrets.env
    [ -n "${PUSHOVER_TOKEN:-}" ] && curl -s --form-string "token=$PUSHOVER_TOKEN" \
        --form-string "user=$PUSHOVER_USER" \
        --form-string "title=${HOST_LABEL} RESTORE COMPLETE" \
        --form-string "message=Restore finished at $(date). Verify the site loads and the DB looks current." \
        https://api.pushover.net/1/messages.json >/dev/null
fi

cat <<EOF

============================================================
  Restore complete: ${HOST_LABEL}
============================================================
  Verify before trusting this box:
    - Load the site in a browser, check a recent post/page is there
    - systemctl status lsws mariadb
    - crontab -l                           (backup schedule back?)
    - The OLS admin panel (https://<ip>:7080) logs in with OLS_ADMIN_USER
      / OLS_ADMIN_PASSWORD from secrets.env, IF this was a bare-box install

  Then re-point DNS/whatever pointed at the old VPS's IP.
============================================================
EOF
