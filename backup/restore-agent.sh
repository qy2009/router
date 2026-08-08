#!/bin/bash
# restore-agent.sh — automated recovery companion to backup-agent.sh.
#
# Run on a FRESH VPS that already has your vps-setup.sh hardening applied.
# Needs secrets-bundle.tar.age (rclone.conf + secrets.env + ssmtp.conf,
# see make-secrets-bundle.sh) sitting next to this script — one passphrase
# unlocks all three. If you'd rather not use the bundle, a bare
# rclone.conf at /root/.config/rclone/rclone.conf also works, and you'll
# be prompted for RESTIC_PASSWORD interactively instead.
#
# Usage:
#   git clone https://github.com/you/router.git && cd router/backup
#   bash restore-agent.sh phx-arm      # the DEAD VPS's host label

set -e
HOST_LABEL="${1:?Usage: restore-agent.sh <host-label>   (the DEAD VPS's label — the Drive folder to restore FROM, not this machine's hostname)}"

echo "[+] Installing restic, rclone, docker..."
apt-get update -qq
apt-get install -y restic docker.io docker-compose-plugin curl
command -v rclone >/dev/null 2>&1 || curl -s https://rclone.org/install.sh | bash

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

export RESTIC_REPOSITORY="rclone:gdrive:Backup_CloudVPS/${HOST_LABEL}"
[ -f /etc/backup-agent/secrets.env ] && source /etc/backup-agent/secrets.env
if [ -z "${RESTIC_PASSWORD:-}" ]; then
    read -r -s -p "RESTIC_PASSWORD for ${HOST_LABEL} (from your password manager): " RESTIC_PASSWORD
    echo
    export RESTIC_PASSWORD
fi

echo "[+] Snapshots available for ${HOST_LABEL}:"
restic snapshots

read -r -p "Restore latest snapshot to / on THIS machine? [y/N] " CONFIRM
[ "$CONFIRM" = "y" ] || { echo "Aborted — nothing changed."; exit 1; }

echo "[+] Restoring..."
restic restore latest --target /
# Every system-files.txt entry and everything under /root and /data lands
# back at its original absolute path — that's the whole point of backing
# them up by real path instead of copying into /root first.

echo "[+] Reinstalling crontab..."
if [ -f /etc/backup-agent/crontab_root.dump ]; then
    crontab /etc/backup-agent/crontab_root.dump
else
    echo "    (no crontab dump found in the snapshot — skipped)"
fi

echo "[+] Reapplying restored system configs..."
[ -f /etc/sysctl.d/99-bbr.conf ] && sysctl --system >/dev/null 2>&1
if [ -f /etc/fail2ban/jail.d/sshd.local ]; then
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban || true
fi
echo "    ssmtp config restored (no daemon to restart — it's used per-invocation)."

# sshd_config was restored too, but deliberately NOT auto-restarting sshd:
# if the restored config has a problem, an automated restart from inside
# this very SSH session could lock you out with no way back in. Review
# and restart it yourself once you're confident.
echo "    /etc/ssh/sshd_config was restored but sshd was NOT restarted."
echo "    Once ready:  sshd -t && systemctl restart sshd"

echo "[+] Bringing docker services back up..."
shopt -s nullglob
for compose in /data/*/docker-compose.yml; do
    dir=$(dirname "$compose")
    echo "    $dir"
    (cd "$dir" && docker compose up -d) || echo "    WARNING: failed to start $dir — check manually"
done
shopt -u nullglob

echo "[+] Re-arming the weekly backup cron for this host..."
if [ -f /root/backup-agent.sh ]; then
    install -m 700 /root/backup-agent.sh /usr/local/bin/backup-agent.sh
    ( crontab -l 2>/dev/null | grep -v backup-agent.sh ; echo "0 3 * * 0 /usr/local/bin/backup-agent.sh" ) | crontab -
else
    echo "    (backup-agent.sh not found alongside this script — copy it over and"
    echo "     re-run install-backup-agent.sh ${HOST_LABEL} to re-arm the cron.)"
fi

# Notify if Pushover creds are already available (they won't be unless
# you've recreated secrets.env — it's excluded from the backup on purpose).
if [ -f /etc/backup-agent/secrets.env ]; then
    source /etc/backup-agent/secrets.env
    [ -n "${PUSHOVER_TOKEN:-}" ] && curl -s --form-string "token=$PUSHOVER_TOKEN" \
        --form-string "user=$PUSHOVER_USER" \
        --form-string "title=${HOST_LABEL} RESTORE COMPLETE" \
        --form-string "message=Restore finished at $(date). Verify docker ps / crontab -l / sshd." \
        https://api.pushover.net/1/messages.json >/dev/null
fi

cat <<EOF

============================================================
  Restore complete: ${HOST_LABEL}
============================================================
  Verify before trusting this box:
    - docker ps                            (expected containers up?)
    - crontab -l                           (schedules back?)
    - cat /etc/ssmtp/ssmtp.conf            (mail config back?)
    - sshd -t && systemctl restart sshd    (once you've reviewed it)

  secrets.env / ssmtp.conf: restored from secrets-bundle.tar.age if it was
  present. If you restored via a bare rclone.conf instead, recreate
  /etc/backup-agent/secrets.env (chmod 600) from your password manager.
============================================================
EOF
