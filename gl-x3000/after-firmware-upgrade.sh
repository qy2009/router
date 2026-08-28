#!/bin/sh

# Reinstall packages commonly removed by a GL.iNet GL-X3000 firmware upgrade.
# Retained UCI configuration is preserved and reused by the reinstalled apps.

set -u
umask 077

REPO_ROOT="https://raw.githubusercontent.com/qy2009/router/main"
OPENCLASH_SOURCE="auto"
INSTALL_OPENCLASH=1
INSTALL_ARGON=1
INSTALL_BACKUP=1
INSTALL_SERVICES=1
CHECK_ONLY=0
TMP_DIR="/tmp/gl-x3000-after-upgrade.$$"
FAILED=""

usage() {
    cat <<'EOF'
Usage: after-firmware-upgrade.sh [OPTIONS]

Reinstall Home Router packages after a GL-X3000 firmware upgrade:
OpenClash, Argon, Lucky, p910nd, FRP client, SNMPD, and the backup cron job.

  --openclash-source auto|cloudrun|official
  --skip-openclash
  --skip-argon
  --skip-backup
  --skip-services       Skip Lucky, p910nd, FRP client, and SNMPD
  --check-only          Detect the router and show planned actions only
  -h, --help

The script installs packages but does not restore or overwrite UCI settings.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --openclash-source)
            [ "$#" -ge 2 ] || { echo "Missing value after --openclash-source" >&2; exit 2; }
            OPENCLASH_SOURCE="$2"
            shift 2
            ;;
        --skip-openclash) INSTALL_OPENCLASH=0; shift ;;
        --skip-argon) INSTALL_ARGON=0; shift ;;
        --skip-backup) INSTALL_BACKUP=0; shift ;;
        --skip-services) INSTALL_SERVICES=0; shift ;;
        --check-only) CHECK_ONLY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$OPENCLASH_SOURCE" in
    auto|cloudrun|official) ;;
    *) echo "Invalid OpenClash source: $OPENCLASH_SOURCE" >&2; exit 2 ;;
esac

[ "$(id -u)" = 0 ] || { echo "Run this script as root." >&2; exit 1; }

[ -r /etc/openwrt_release ] && . /etc/openwrt_release
ARCH="${DISTRIB_ARCH:-$(uname -m)}"
RELEASE="${DISTRIB_RELEASE:-unknown}"

if command -v apk >/dev/null 2>&1 && ! command -v opkg >/dev/null 2>&1; then
    PKG_MANAGER=apk
elif command -v opkg >/dev/null 2>&1; then
    PKG_MANAGER=opkg
else
    echo "Neither opkg nor apk is available." >&2
    exit 1
fi

echo "Detected: OpenWrt $RELEASE, $ARCH, $PKG_MANAGER"
echo "Plan: OpenClash=$INSTALL_OPENCLASH Argon=$INSTALL_ARGON services=$INSTALL_SERVICES backup=$INSTALL_BACKUP"

if [ "$CHECK_ONLY" -eq 1 ]; then
    echo "Standard packages: lucky luci-app-lucky p910nd luci-app-p910nd frpc luci-app-frpc snmpd luci-app-snmpd"
    echo "Check completed; no packages or files were changed."
    exit 0
fi

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
        return 1
    fi
}

record_failure() {
    item="$1"
    echo "ERROR: $item failed" >&2
    FAILED="$FAILED $item"
}

package_installed() {
    package="$1"
    case "$PKG_MANAGER" in
        opkg) opkg status "$package" 2>/dev/null | grep -q '^Status: .* installed$' ;;
        apk) apk info -e "$package" >/dev/null 2>&1 ;;
    esac
}

package_install() {
    package="$1"
    if package_installed "$package"; then
        echo "$package is already installed."
        return 0
    fi
    echo "Installing $package..."
    case "$PKG_MANAGER" in
        opkg) opkg install "$package" ;;
        apk) apk add "$package" ;;
    esac
}

if [ "$INSTALL_SERVICES" -eq 1 ]; then
    echo "Refreshing package indexes..."
    case "$PKG_MANAGER" in
        opkg) opkg update || record_failure package-index ;;
        apk) apk update || record_failure package-index ;;
    esac

    for package in \
        lucky luci-app-lucky \
        p910nd luci-app-p910nd \
        frpc luci-app-frpc \
        snmpd luci-app-snmpd
    do
        package_install "$package" || record_failure "$package"
    done
fi

if [ "$INSTALL_OPENCLASH" -eq 1 ] || [ "$INSTALL_ARGON" -eq 1 ]; then
    SHARED_INSTALLER="$TMP_DIR/openclash-argon-installer.sh"
    if download "$REPO_ROOT/gl-be3600/after-firmware-upgrade.sh" "$SHARED_INSTALLER"; then
        chmod 700 "$SHARED_INSTALLER"
        SHARED_ARGS="--openclash-source $OPENCLASH_SOURCE"
        [ "$INSTALL_OPENCLASH" -eq 1 ] || SHARED_ARGS="$SHARED_ARGS --skip-openclash"
        [ "$INSTALL_ARGON" -eq 1 ] || SHARED_ARGS="$SHARED_ARGS --skip-argon"
        # Arguments are generated only from the validated options above.
        sh "$SHARED_INSTALLER" $SHARED_ARGS || record_failure openclash-argon
    else
        record_failure openclash-argon-download
    fi
fi

if [ "$INSTALL_BACKUP" -eq 1 ]; then
    BACKUP_INSTALLER="$TMP_DIR/install-backup.sh"
    if download "$REPO_ROOT/gl-x3000/install-backup.sh" "$BACKUP_INSTALLER"; then
        chmod 700 "$BACKUP_INSTALLER"
        sh "$BACKUP_INSTALLER" || record_failure backup-installer
    else
        record_failure backup-installer-download
    fi
fi

if [ "$INSTALL_SERVICES" -eq 1 ]; then
    for service in lucky p910nd frpc snmpd; do
        [ -x "/etc/init.d/$service" ] || { record_failure "$service-init"; continue; }
        /etc/init.d/"$service" enable || record_failure "$service-enable"
        /etc/init.d/"$service" restart || record_failure "$service-start"
    done
fi

# Preserve the user's OpenClash enabled/disabled setting.
if [ "$INSTALL_OPENCLASH" -eq 1 ] && [ -x /etc/init.d/openclash ]; then
    /etc/init.d/openclash enable || true
    if [ "$(uci -q get openclash.config.enable 2>/dev/null || echo 0)" = "1" ]; then
        /etc/init.d/openclash restart || record_failure openclash-start
    else
        echo "OpenClash is installed but remains disabled by its retained UCI setting."
    fi
fi

rm -f /tmp/luci-indexcache 2>/dev/null || true
if [ -x /etc/init.d/uhttpd ]; then
    /etc/init.d/uhttpd reload 2>/dev/null || /etc/init.d/uhttpd restart || true
fi

if [ -n "$FAILED" ]; then
    echo "Post-firmware recovery completed with failures:$FAILED" >&2
    exit 1
fi

echo "Post-firmware recovery completed successfully."
echo "Retained router settings were not overwritten."
