#!/usr/bin/env bash
# Read-only verification of a PHX backup directory.
set -Eeuo pipefail
dir=${1:?Usage: verify-backup.sh BACKUP_DIRECTORY}
cd "$dir"
sha256sum -c SHA256SUMS
gzip -t sysupgrade.tar.gz
tar -tzf sysupgrade.tar.gz > /dev/null
echo 'Archive integrity verified.'
echo 'Router:'
cat router-info.txt
echo 'Critical paths:'
for path in \
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
  grep -Fx "$path" contents.txt
done
