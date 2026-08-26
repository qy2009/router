#!/bin/sh
set -eu

# GL.iNet/OpenWrt configuration backup. The resulting archive contains secrets.
umask 077

OUT_DIR=/tmp
ENCRYPT=0

usage() {
  cat <<'EOF'
Usage: backup-router.sh [-o OUTPUT_DIRECTORY] [--encrypt]

Creates a dated backup containing GL.iNet/OpenWrt configuration, VPN material,
Wi-Fi settings, Tailscale state, GoodCloud configuration, and OpenClash data.

  -o DIR       Write the backup to DIR (default: /tmp)
  --encrypt    Encrypt with AES-256; OpenSSL will ask for a passphrase
  -h, --help   Show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      [ "$#" -ge 2 ] || { echo "Missing value after -o" >&2; exit 2; }
      OUT_DIR=$2
      shift 2
      ;;
    --encrypt)
      ENCRYPT=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[ "$(id -u)" = 0 ] || { echo "Run this script as root." >&2; exit 1; }
mkdir -p "$OUT_DIR"
[ -d "$OUT_DIR" ] && [ -w "$OUT_DIR" ] || {
  echo "Output directory is not writable: $OUT_DIR" >&2
  exit 1
}

STAMP=$(date +%Y%m%d-%H%M%S)
HOST=$(uci -q get system.@system[0].hostname 2>/dev/null || hostname 2>/dev/null || echo gl-be3600)
SAFE_HOST=$(printf '%s' "$HOST" | tr -c 'A-Za-z0-9._-' '_')
WORK=/tmp/gl-be3600-backup.$$
ARCHIVE="$OUT_DIR/${SAFE_HOST}-backup-${STAMP}.tar.gz"

cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

mkdir -p "$WORK/payload" "$WORK/metadata"

copy_path() {
  SOURCE=$1
  [ -e "$SOURCE" ] || return 0
  PARENT=$(dirname "$SOURCE")
  mkdir -p "$WORK/payload$PARENT"
  cp -a "$SOURCE" "$WORK/payload$PARENT/"
}

# /etc/config covers GL.iNet, Wi-Fi, firewall, VPN, GoodCloud (gl-cloud),
# Tailscale UCI settings, OpenClash UCI settings, and installed service config.
copy_path /etc/config

# Stateful data and credentials that sysupgrade backups may not always retain.
for PATH_ITEM in \
  /etc/openclash \
  /etc/tailscale \
  /etc/openvpn \
  /etc/wireguard \
  /etc/dropbear \
  /etc/crontabs \
  /etc/rc.local \
  /etc/sysupgrade.conf \
  /etc/uhttpd.crt \
  /etc/uhttpd.key \
  /root/.ssh
do
  copy_path "$PATH_ITEM"
done

{
  echo "created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "hostname=$HOST"
  echo "kernel=$(uname -r)"
  echo "machine=$(uname -m)"
  [ -r /etc/openwrt_release ] && cat /etc/openwrt_release
} > "$WORK/metadata/router.txt"

if command -v opkg >/dev/null 2>&1; then
  opkg list-installed > "$WORK/metadata/opkg-list-installed.txt"
elif command -v apk >/dev/null 2>&1; then
  apk list --installed > "$WORK/metadata/apk-list-installed.txt"
fi

cat > "$WORK/RESTORE.txt" <<'EOF'
This archive contains private keys, VPN credentials, Wi-Fi passwords, and tokens.
Keep it private. To inspect it, extract into an empty directory.

After a firmware upgrade, restore only configuration compatible with the new
firmware. Copy payload/etc/config and needed service directories into place,
then reinstall missing packages before restarting services or rebooting.
EOF

tar -C "$WORK" -czf "$ARCHIVE" metadata payload RESTORE.txt
chmod 600 "$ARCHIVE"

if [ "$ENCRYPT" -eq 1 ]; then
  command -v openssl >/dev/null 2>&1 || {
    echo "OpenSSL is required for --encrypt." >&2
    exit 1
  }
  ENCRYPTED="${ARCHIVE}.enc"
  openssl enc -aes-256-cbc -salt -pbkdf2 -iter 200000 \
    -in "$ARCHIVE" -out "$ENCRYPTED"
  rm -f "$ARCHIVE"
  ARCHIVE=$ENCRYPTED
fi

if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$ARCHIVE" > "${ARCHIVE}.sha256"
fi

echo "Backup created: $ARCHIVE"
echo "WARNING: This backup contains secrets. Do not commit it to GitHub."


