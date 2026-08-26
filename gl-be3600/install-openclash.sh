#!/bin/sh
set -eu

# Installs or reinstalls OpenClash after a firmware upgrade.
# CloudRunFilesBuilder is used only when its asset matches the router's package
# manager and architecture. Older opkg firmware safely uses the official all.ipk.

CLOUD_REPO=wkccd/CloudRunFilesBuilder
OFFICIAL_REPO=vernesong/OpenClash
SOURCE=auto
TMP_DIR=/tmp/openclash-install.$$

usage() {
  cat <<'EOF'
Usage: install-openclash.sh [--source auto|cloudrun|official]

  auto      CloudRun on compatible firmware; official .ipk on older opkg builds
  cloudrun  Require a matching CloudRunFilesBuilder .run asset
  official  Install the latest official luci-app-openclash all-package
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source)
      [ "$#" -ge 2 ] || { echo "Missing value after --source" >&2; exit 2; }
      SOURCE=$2
      shift 2
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

case "$SOURCE" in auto|cloudrun|official) ;; *) echo "Invalid source: $SOURCE" >&2; exit 2;; esac
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

github_json() {
  REPO=$1
  ENDPOINT=$2
  download "https://api.github.com/repos/$REPO/$ENDPOINT" "$TMP_DIR/github.json"
}

json_urls() {
  jsonfilter -i "$TMP_DIR/github.json" -e '@.assets[*].browser_download_url'
}

[ -r /etc/openwrt_release ] && . /etc/openwrt_release
ARCH=${DISTRIB_ARCH:-$(uname -m)}
RELEASE=${DISTRIB_RELEASE:-unknown}

if command -v apk >/dev/null 2>&1 && ! command -v opkg >/dev/null 2>&1; then
  PKG_MANAGER=apk
else
  PKG_MANAGER=opkg
fi

install_official() {
  [ "$PKG_MANAGER" = opkg ] || {
    echo "Official .ipk mode requires opkg; this router uses $PKG_MANAGER." >&2
    exit 1
  }
  command -v jsonfilter >/dev/null 2>&1 || {
    echo "jsonfilter is required." >&2
    exit 1
  }
  echo "Fetching latest official OpenClash release..."
  github_json "$OFFICIAL_REPO" releases/latest
  URL=$(json_urls | grep -E '/luci-app-openclash_[^/]+_all\.ipk$' | head -n 1 || true)
  [ -n "$URL" ] || { echo "No official OpenClash all.ipk asset found." >&2; exit 1; }
  FILE="$TMP_DIR/openclash.ipk"
  download "$URL" "$FILE"
  opkg update
  opkg install "$FILE"
}

install_cloudrun() {
  command -v jsonfilter >/dev/null 2>&1 || {
    echo "jsonfilter is required." >&2
    return 1
  }
  echo "Fetching latest CloudRunFilesBuilder release..."
  github_json "$CLOUD_REPO" releases/latest

  case "$PKG_MANAGER:$ARCH" in
    apk:aarch64_cortex-a53|apk:aarch64)
      PATTERN='/25-openclash-aarch64_cortex-a53-v[^/]+\.run$'
      ;;
    apk:x86_64)
      PATTERN='/25-openclash-x86-64-v[^/]+\.run$'
      ;;
    opkg:aarch64_cortex-a53|opkg:aarch64)
      PATTERN='/24-openclash-aarch64_cortex-a53-v[^/]+\.run$'
      ;;
    opkg:x86_64)
      PATTERN='/24-openclash-x86-64-v[^/]+\.run$'
      ;;
    *)
      echo "No known CloudRun asset pattern for $PKG_MANAGER/$ARCH." >&2
      return 1
      ;;
  esac

  URL=$(json_urls | grep -E "$PATTERN" | head -n 1 || true)
  [ -n "$URL" ] || {
    echo "No compatible CloudRun OpenClash asset in the latest release." >&2
    echo "Refusing to install a package for a different firmware generation." >&2
    return 1
  }
  FILE="$TMP_DIR/openclash.run"
  download "$URL" "$FILE"
  chmod 700 "$FILE"
  sh "$FILE"
}

case "$SOURCE" in
  official)
    install_official
    ;;
  cloudrun)
    install_cloudrun
    ;;
  auto)
    case "$PKG_MANAGER:$RELEASE" in
      apk:25.*)
        install_cloudrun
        ;;
      opkg:24.*)
        install_cloudrun || install_official
        ;;
      opkg:*)
        echo "OpenWrt $RELEASE uses opkg; using the official all.ipk to avoid incompatible CloudRun 25 packages."
        install_official
        ;;
      *)
        echo "Unsupported package manager/firmware: $PKG_MANAGER $RELEASE" >&2
        exit 1
        ;;
    esac
    ;;
esac

if [ -x /etc/init.d/openclash ]; then
  /etc/init.d/openclash enable
fi

echo "OpenClash installation completed."
echo "Existing configuration under /etc/config/openclash and /etc/openclash was preserved."

