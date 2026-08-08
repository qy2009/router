#!/bin/bash
# make-secrets-bundle.sh — bundle rclone.conf + backup-agent secrets.env +
# ssmtp.conf into ONE age-passphrase-encrypted file. This is what makes
# "clone the repo, type one passphrase" a complete bootstrap on a new VPS.
#
# Run this ONCE, on a machine that already has all three files configured
# for real (e.g. your first working VPS), then commit the resulting
# secrets-bundle.tar.age to the same GitHub repo as the scripts — it's
# safe to be public, only the passphrase opens it. Re-run whenever any of
# the three files change (new SMTP password, rotated restic password...).

set -e
if ! command -v age >/dev/null 2>&1; then
    echo "[+] Installing age..."
    if command -v brew >/dev/null 2>&1; then
        brew install age
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y age
    else
        echo "[x] Don't know how to install age on this system (no brew or apt-get)."
        echo "    Install it yourself: https://github.com/FiloSottile/age#installation"
        exit 1
    fi
fi

RCLONE_CONF="${RCLONE_CONF:-/root/.config/rclone/rclone.conf}"
SECRETS_ENV="${SECRETS_ENV:-/etc/backup-agent/secrets.env}"
SSMTP_CONF="${SSMTP_CONF:-/etc/ssmtp/ssmtp.conf}"
OUT="${1:-secrets-bundle.tar.age}"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
DATA_STAGE="$STAGE/data"   # kept separate from bundle.tar's own location below,
mkdir -p "$DATA_STAGE"     # otherwise tar (especially bsdtar on macOS) refuses
                            # with "can't add archive to itself"

MISSING=""
[ -f "$RCLONE_CONF" ] && cp "$RCLONE_CONF" "$DATA_STAGE/rclone.conf" || MISSING="$MISSING rclone.conf"
[ -f "$SECRETS_ENV" ]  && cp "$SECRETS_ENV"  "$DATA_STAGE/secrets.env" || MISSING="$MISSING secrets.env"
[ -f "$SSMTP_CONF" ]   && cp "$SSMTP_CONF"   "$DATA_STAGE/ssmtp.conf"  || MISSING="$MISSING ssmtp.conf"
if [ -n "$MISSING" ]; then
    echo "[x] Not found, aborting:$MISSING"
    echo "    Set RCLONE_CONF / SECRETS_ENV / SSMTP_CONF to the right paths and re-run."
    exit 1
fi

tar -C "$DATA_STAGE" -cf "$STAGE/bundle.tar" .

echo "[+] You'll be asked to set a passphrase now."
echo "    This ONE passphrase is the only thing you need to keep in your"
echo "    password manager going forward — it unlocks rclone.conf,"
echo "    secrets.env, and ssmtp.conf together."
age -p -o "$OUT" "$STAGE/bundle.tar"

echo ""
echo "[+] Wrote $OUT"
echo "    Commit it next to your backup scripts in GitHub (or copy to Drive)."
echo "    It's ciphertext — safe in a public repo."
