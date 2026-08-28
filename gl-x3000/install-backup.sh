#!/bin/sh
set -eu

# Installs the GL-X3000 backup job without overwriting notification secrets.

umask 077

REPO_RAW="https://raw.githubusercontent.com/qy2009/router/main/gl-x3000"
INSTALL_PATH="/usr/local/bin/router-backup.sh"
NOTIFY_ENV="/etc/router-backup-notify.env"
NOTIFY_EXAMPLE="/etc/router-backup-notify.env.example"
CRON_FILE="/etc/crontabs/root"
SYSUPGRADE_CONF="/etc/sysupgrade.conf"
SCHEDULE="0 2 * * 0"
LOCAL_SCRIPT=""
INSTALL_CRON=1
TMP_DIR="/tmp/gl-x3000-backup-install.$$"

usage() {
    cat <<'EOF'
Usage: install-backup.sh [OPTIONS]

Install the GL-X3000 SD-card backup script and its weekly cron schedule.

  --script FILE       Install this local router-backup.sh instead of downloading
  --schedule SPEC     Cron schedule (default: "0 2 * * 0", Sunday at 02:00)
  --no-cron           Install the script but do not change cron
  -h, --help          Show this help

The installer preserves /etc/router-backup-notify.env when it already exists.
It also adds the script and notification file to /etc/sysupgrade.conf.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --script)
            [ "$#" -ge 2 ] || { echo "Missing value after --script" >&2; exit 2; }
            LOCAL_SCRIPT="$2"
            shift 2
            ;;
        --schedule)
            [ "$#" -ge 2 ] || { echo "Missing value after --schedule" >&2; exit 2; }
            SCHEDULE="$2"
            shift 2
            ;;
        --no-cron)
            INSTALL_CRON=0
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

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT INT TERM
mkdir -p "$TMP_DIR"

download() {
    url="$1"
    dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --connect-timeout 20 "$url" -o "$dest"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$dest" "$url"
    else
        echo "curl or wget is required." >&2
        exit 1
    fi
}

SOURCE="$TMP_DIR/router-backup.sh"
if [ -n "$LOCAL_SCRIPT" ]; then
    [ -f "$LOCAL_SCRIPT" ] || { echo "Backup script not found: $LOCAL_SCRIPT" >&2; exit 1; }
    cp "$LOCAL_SCRIPT" "$SOURCE"
else
    echo "Downloading router-backup.sh..."
    download "$REPO_RAW/router-backup.sh" "$SOURCE"
fi

sh -n "$SOURCE"
mkdir -p "$(dirname "$INSTALL_PATH")"

if [ -f "$INSTALL_PATH" ] && ! cmp -s "$SOURCE" "$INSTALL_PATH"; then
    ROLLBACK="$INSTALL_PATH.bak-$(date '+%Y%m%d-%H%M%S')"
    cp -p "$INSTALL_PATH" "$ROLLBACK"
    echo "Saved rollback copy: $ROLLBACK"
fi

cp "$SOURCE" "$INSTALL_PATH"
chmod 755 "$INSTALL_PATH"

if [ ! -e "$NOTIFY_EXAMPLE" ]; then
    cat > "$NOTIFY_EXAMPLE" <<'EOF'
# Copy this file to /etc/router-backup-notify.env and replace the placeholders.
PUSHOVER_USER='CHANGE_ME'
PUSHOVER_TOKEN='CHANGE_ME'
# Use the private/Tailscale Kuma address when the public site uses Cloudflare Access.
UPTIME_PUSH_URL='http://UPTIME-KUMA-TAILSCALE-IP:3001/api/push/CHANGE_ME'
PUSHOVER_NOTIFY_SUCCESS='1'
EOF
    chmod 600 "$NOTIFY_EXAMPLE"
fi

touch "$SYSUPGRADE_CONF"
for retained_file in "$INSTALL_PATH" "$NOTIFY_ENV"; do
    grep -qxF "$retained_file" "$SYSUPGRADE_CONF" 2>/dev/null || \
        printf '%s\n' "$retained_file" >> "$SYSUPGRADE_CONF"
done

if [ "$INSTALL_CRON" -eq 1 ]; then
    mkdir -p "$(dirname "$CRON_FILE")"
    touch "$CRON_FILE"
    CRON_TMP="$TMP_DIR/crontab.root"
    grep -vF " $INSTALL_PATH" "$CRON_FILE" > "$CRON_TMP" || true
    printf '%s %s\n' "$SCHEDULE" "$INSTALL_PATH" >> "$CRON_TMP"
    cp "$CRON_TMP" "$CRON_FILE"
    chmod 600 "$CRON_FILE"

    if [ -x /etc/init.d/cron ]; then
        /etc/init.d/cron enable
        /etc/init.d/cron restart
    fi
fi

echo "Backup script installed: $INSTALL_PATH"
if [ "$INSTALL_CRON" -eq 1 ]; then
    echo "Cron installed: $SCHEDULE $INSTALL_PATH"
fi
if [ -r "$NOTIFY_ENV" ]; then
    echo "Notification configuration preserved: $NOTIFY_ENV"
else
    echo "Notifications are not configured yet. See: $NOTIFY_EXAMPLE"
fi
echo "Run a verified backup with: $INSTALL_PATH"
