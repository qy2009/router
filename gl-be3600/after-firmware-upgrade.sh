#!/bin/sh
set -eu

# Reinstall the packages normally removed by a GL.iNet firmware upgrade while
# leaving retained router, VPN, Wi-Fi, GoodCloud, and OpenClash settings alone.
umask 077

REPO_RAW=https://raw.githubusercontent.com/qy2009/router/main/gl-be3600
ARGON_REPO=jerrykuku/luci-theme-argon
OPENCLASH_SOURCE=auto
INSTALL_OPENCLASH=1
INSTALL_ARGON=1
TMP_DIR=/tmp/gl-be3600-after-upgrade.$$

usage() {
  cat <<'EOF'
Usage: after-firmware-upgrade.sh [OPTIONS]

Reinstalls OpenClash and the LuCI Argon theme after a firmware upgrade. It does
not restore or overwrite router configuration.

  --openclash-source auto|cloudrun|official
                              Select the source passed to install-openclash.sh
  --skip-openclash            Do not install OpenClash
  --skip-argon                Do not install the Argon theme
  -h, --help                  Show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --openclash-source)
      [ "$#" -ge 2 ] || { echo "Missing value after --openclash-source" >&2; exit 2; }
      OPENCLASH_SOURCE=$2
      shift 2
      ;;
    --skip-openclash)
      INSTALL_OPENCLASH=0
      shift
      ;;
    --skip-argon)
      INSTALL_ARGON=0
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

case "$OPENCLASH_SOURCE" in
  auto|cloudrun|official) ;;
  *) echo "Invalid OpenClash source: $OPENCLASH_SOURCE" >&2; exit 2 ;;
esac

[ "$(id -u)" = 0 ] || { echo "Run this script as root." >&2; exit 1; }

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT INT TERM
mkdir -p "$TMP_DIR"

download() {
  URL=$1
  DEST=$2
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 20 "$URL" -o "$DEST"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$DEST" "$URL"
  else
    echo "curl or wget is required." >&2
    exit 1
  fi
}

if command -v apk >/dev/null 2>&1 && ! command -v opkg >/dev/null 2>&1; then
  PKG_MANAGER=apk
else
  PKG_MANAGER=opkg
fi

install_openclash() {
  echo "Downloading the repository's OpenClash installer..."
  INSTALLER="$TMP_DIR/install-openclash.sh"
  download "$REPO_RAW/install-openclash.sh" "$INSTALLER"
  chmod 700 "$INSTALLER"
  sh "$INSTALLER" --source "$OPENCLASH_SOURCE"
}

install_argon() {
  command -v jsonfilter >/dev/null 2>&1 || {
    echo "jsonfilter is required to select the latest Argon release." >&2
    exit 1
  }

  echo "Fetching the latest official Argon release..."
  RELEASE_JSON="$TMP_DIR/argon-release.json"
  download "https://api.github.com/repos/$ARGON_REPO/releases/latest" "$RELEASE_JSON"

  case "$PKG_MANAGER" in
    opkg)
      THEME_URL=$(jsonfilter -i "$RELEASE_JSON" -e '@.assets[*].browser_download_url' | \
        grep -E '/luci-theme-argon_[^/]+_all\.ipk$' | head -n 1 || true)
      CONFIG_URL=$(jsonfilter -i "$RELEASE_JSON" -e '@.assets[*].browser_download_url' | \
        grep -E '/luci-app-argon-config_[^/]+_all\.ipk$' | head -n 1 || true)
      [ -n "$THEME_URL" ] || { echo "No Argon .ipk was found in the latest release." >&2; exit 1; }
      THEME_FILE="$TMP_DIR/luci-theme-argon.ipk"
      download "$THEME_URL" "$THEME_FILE"
      opkg update
      if [ -n "$CONFIG_URL" ]; then
        CONFIG_FILE="$TMP_DIR/luci-app-argon-config.ipk"
        download "$CONFIG_URL" "$CONFIG_FILE"
        opkg install "$THEME_FILE" "$CONFIG_FILE"
      else
        echo "Argon configuration companion not found; installing the theme only."
        opkg install "$THEME_FILE"
      fi
      ;;
    apk)
      THEME_URL=$(jsonfilter -i "$RELEASE_JSON" -e '@.assets[*].browser_download_url' | \
        grep -E '/luci-theme-argon-[^/]+\.apk$' | head -n 1 || true)
      CONFIG_URL=$(jsonfilter -i "$RELEASE_JSON" -e '@.assets[*].browser_download_url' | \
        grep -E '/luci-app-argon-config-[^/]+\.apk$' | head -n 1 || true)
      [ -n "$THEME_URL" ] || { echo "No Argon .apk was found in the latest release." >&2; exit 1; }
      THEME_FILE="$TMP_DIR/luci-theme-argon.apk"
      download "$THEME_URL" "$THEME_FILE"
      if [ -n "$CONFIG_URL" ]; then
        CONFIG_FILE="$TMP_DIR/luci-app-argon-config.apk"
        download "$CONFIG_URL" "$CONFIG_FILE"
        apk add --allow-untrusted "$THEME_FILE" "$CONFIG_FILE"
      else
        echo "Argon configuration companion not found; installing the theme only."
        apk add --allow-untrusted "$THEME_FILE"
      fi
      ;;
  esac

  # Force LuCI to rebuild its menu/theme cache without changing saved settings.
  rm -f /tmp/luci-indexcache 2>/dev/null || true
  if [ -x /etc/init.d/uhttpd ]; then
    /etc/init.d/uhttpd reload 2>/dev/null || /etc/init.d/uhttpd restart
  fi
}

echo "Detected package manager: $PKG_MANAGER"

if [ "$INSTALL_OPENCLASH" -eq 1 ]; then
  install_openclash
else
  echo "Skipping OpenClash."
fi

if [ "$INSTALL_ARGON" -eq 1 ]; then
  install_argon
else
  echo "Skipping Argon."
fi

echo "Post-firmware package installation completed."
echo "Existing router and OpenClash settings were not restored or overwritten."

