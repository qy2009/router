#!/usr/bin/env bash
# Verify and copy an archive to /tmp on a compatible target. Never applies it.
set -Eeuo pipefail
umask 077
target=${1:?Usage: stage-restore-from-phx.sh ROOT@TARGET [BACKUP_DIRECTORY]}
dir=${2:-/data/router-backups/xia-router/latest}
"$(dirname "$0")/verify-backup.sh" "$dir" >/dev/null

expected_model=$(grep -m1 '^GL.iNet ' "$dir/router-info.txt")
actual_model=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" 'cat /tmp/sysinfo/model')
if [[ "$actual_model" != "$expected_model" ]]; then
  echo "Refusing to stage: backup is for '$expected_model', target is '$actual_model'" >&2
  exit 1
fi

archive=/tmp/xia-router-sysupgrade.tar.gz
scp -q "$dir/sysupgrade.tar.gz" "$target:$archive"
local_hash=$(sha256sum "$dir/sysupgrade.tar.gz" | awk '{print $1}')
remote_hash=$(ssh -o BatchMode=yes "$target" "sha256sum '$archive'" | awk '{print $1}')
[[ "$local_hash" == "$remote_hash" ]] || {
  echo 'Transferred archive checksum mismatch' >&2
  exit 1
}
echo "Staged and verified $archive on $target ($actual_model)."
echo 'No router configuration was changed. Review firmware and old-device status before running sysupgrade -r.'
