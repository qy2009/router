#!/bin/sh
set -eu

# Configure remote syslog and install the Tailscale boot-order fix.

umask 077

REPO_RAW="https://raw.githubusercontent.com/qy2009/router/main/gl-x3000"
INSTALL_PATH="/etc/init.d/remote-syslog-rebind"
SYSUPGRADE_CONF="/etc/sysupgrade.conf"
TARGET_IP="100.111.111.118"
TARGET_PORT="1516"
LOCAL_SCRIPT=""
TMP_DIR="/tmp/gl-x3000-remote-syslog-install.$$"

usage() {
    cat <<'EOF'
Usage: install-remote-syslog.sh [OPTIONS]

Configure remote syslog over Tailscale and install its boot-order fix.

  --script FILE       Install this local init script instead of downloading
  --target IP          Syslog receiver (default: 100.111.111.118)
  --port PORT          UDP port (default: 1516)
  -h, --help           Show this help
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --script)
            [ "$#" -ge 2 ] || { echo "Missing value after --script" >&2; exit 2; }
            LOCAL_SCRIPT="$2"
            shift 2
            ;;
        --target)
            [ "$#" -ge 2 ] || { echo "Missing value after --target" >&2; exit 2; }
            TARGET_IP="$2"
            shift 2
            ;;
        --port)
            [ "$#" -ge 2 ] || { echo "Missing value after --port" >&2; exit 2; }
            TARGET_PORT="$2"
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[ "$(id -u)" = 0 ] || { echo "Run this script as root." >&2; exit 1; }
case "$TARGET_PORT" in
    ''|*[!0-9]*) echo "Port must be numeric." >&2; exit 2 ;;
esac

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

SOURCE="$TMP_DIR/remote-syslog-rebind"
if [ -n "$LOCAL_SCRIPT" ]; then
    [ -f "$LOCAL_SCRIPT" ] || { echo "Init script not found: $LOCAL_SCRIPT" >&2; exit 1; }
    cp "$LOCAL_SCRIPT" "$SOURCE"
else
    download "$REPO_RAW/remote-syslog-rebind.init" "$SOURCE"
fi

sh -n "$SOURCE"
if [ -f "$INSTALL_PATH" ] && ! cmp -s "$SOURCE" "$INSTALL_PATH"; then
    rollback="$INSTALL_PATH.bak-$(date '+%Y%m%d-%H%M%S')"
    cp -p "$INSTALL_PATH" "$rollback"
    echo "Saved rollback copy: $rollback"
fi

cp "$SOURCE" "$INSTALL_PATH"
chmod 755 "$INSTALL_PATH"

uci set system.@system[0].log_ip="$TARGET_IP"
uci set system.@system[0].log_port="$TARGET_PORT"
uci set system.@system[0].log_proto='udp'
uci set system.@system[0].log_remote='1'
uci commit system

touch "$SYSUPGRADE_CONF"
grep -qxF "$INSTALL_PATH" "$SYSUPGRADE_CONF" 2>/dev/null || \
    printf '%s\n' "$INSTALL_PATH" >> "$SYSUPGRADE_CONF"

"$INSTALL_PATH" enable
"$INSTALL_PATH" restart

echo "Remote syslog configured for $TARGET_IP:$TARGET_PORT/udp."
echo "The boot-time Tailscale rebind service is enabled."
