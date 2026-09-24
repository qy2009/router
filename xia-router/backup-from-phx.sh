#!/usr/bin/env bash
# Run on phx-arm as root. Pull a verified configuration archive over Tailscale.
set -Eeuo pipefail
umask 077

ROUTER=${ROUTER:-root@100.111.111.119}
STORE=${STORE:-/data/router-backups/xia-router}
MIRROR=${MIRROR:-/gdrive/Backup/xia-router}
KEEP=${KEEP:-14}
MONITOR_ENV=/etc/xia-router-backup-monitor.env
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 "$ROUTER")

KUMA_PUSH_URL=''
if [[ -r "$MONITOR_ENV" ]]; then source "$MONITOR_ENV"; fi
kuma_push() {
  local status=$1 message=$2 response
  [[ -n "$KUMA_PUSH_URL" ]] || return 0
  response=$(curl -fsS --connect-timeout 8 --max-time 20 --get \
    --data-urlencode "status=$status" --data-urlencode "msg=$message" \
    "$KUMA_PUSH_URL") || return 1
  [[ "$response" == *'"ok":true'* ]]
}

mkdir -p "$STORE"
chmod 700 "$STORE"
exec 9>"$STORE/.backup.lock"
flock -n 9 || { echo 'Backup already running' >&2; exit 1; }

stamp=$(date -u +%Y%m%dT%H%M%SZ)
tmp=$(mktemp -d "$STORE/.incoming.XXXXXXXX")
mirror_tmp=''
cleanup() {
  rc=$?
  if [ -n "$tmp" ] && [ -d "$tmp" ]; then rm -rf -- "$tmp"; fi
  if [ -n "$mirror_tmp" ] && [ -d "$mirror_tmp" ]; then rm -rf -- "$mirror_tmp"; fi
  if (( rc != 0 )); then
    printf '%s exit=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" > "$STORE/last-failure.txt"
    logger -t xia-router-backup "Backup failed with exit code $rc"
    kuma_push down "xia-router backup failed (exit $rc)" || true
  fi
}
trap cleanup EXIT

"${SSH[@]}" 'sysupgrade -b -' > "$tmp/sysupgrade.tar.gz"
test -s "$tmp/sysupgrade.tar.gz"
gzip -t "$tmp/sysupgrade.tar.gz"
tar -tzf "$tmp/sysupgrade.tar.gz" > "$tmp/contents.txt"

for path in \
  etc/config/openclash \
  etc/openclash/config/config.yaml \
  etc/openclash/custom/xia-resilience.rb \
  etc/openclash/custom/xia-provider-stability.rb \
  etc/openclash/custom/tailscale-bypass.sh \
  etc/openclash/core/clash_meta \
  etc/openclash/node-diagnostics.sh \
  etc/openclash/group-diagnostics.sh \
  etc/openclash/post-upgrade-check.sh \
  etc/frp/frpc.toml \
  etc/tailscale/tailscaled.state \
  etc/crontabs/root
do
  grep -Fxq "$path" "$tmp/contents.txt" || {
    echo "Required file missing from archive: $path" >&2
    exit 1
  }
done

"${SSH[@]}" 'opkg list-installed' > "$tmp/packages.txt"
"${SSH[@]}" 'date -u; cat /etc/openwrt_release; cat /tmp/sysinfo/model 2>/dev/null || true; uname -a' > "$tmp/router-info.txt"
test -s "$tmp/packages.txt"
(cd "$tmp" && sha256sum sysupgrade.tar.gz packages.txt router-info.txt contents.txt > SHA256SUMS && sha256sum -c SHA256SUMS)

dest="$STORE/$stamp"
test ! -e "$dest"
mv -- "$tmp" "$dest"
tmp=''

# Refuse to write into the underlying root filesystem if the rclone mount drops.
[[ $(findmnt -T /gdrive -n -o TARGET) == /gdrive ]]
[[ $(findmnt -T /gdrive -n -o SOURCE) == 'gdrive:' ]]
mkdir -p "$MIRROR"
mirror_tmp="$MIRROR/.incoming-$stamp-$$"
mkdir "$mirror_tmp"
cp -r -- "$dest"/. "$mirror_tmp"/
(cd "$mirror_tmp" && sha256sum -c SHA256SUMS >/dev/null)
test ! -e "$MIRROR/$stamp"
mv -- "$mirror_tmp" "$MIRROR/$stamp"
mirror_tmp=''
printf '%s\n' "$stamp" > "$MIRROR/latest.txt.part"
mv -- "$MIRROR/latest.txt.part" "$MIRROR/latest.txt"

ln -sfn "$stamp" "$STORE/latest"
echo "Verified xia-router backup: $dest"
echo "Verified Google Drive copy: $MIRROR/$stamp"
echo "Archive bytes: $(stat -c %s "$dest/sysupgrade.tar.gz")"
printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$dest" > "$STORE/last-success.txt"
kuma_push up 'xia-router local and Google Drive backups verified' || {
  echo 'WARNING: Uptime Kuma heartbeat could not be delivered' >&2
}

# Only rotate timestamp-named backup directories inside the fixed store.
mapfile -t old < <(find "$STORE" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
  -regex "$STORE/[0-9]{8}T[0-9]{6}Z" | sort)
if (( ${#old[@]} > KEEP )); then
  for path in "${old[@]:0:${#old[@]}-KEEP}"; do
    [[ "$path" == "$STORE"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z ]] || exit 1
    rm -rf -- "$path"
  done
fi
