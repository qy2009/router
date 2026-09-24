#!/bin/ash
# Read-only checks after a GL-MT2500 firmware upgrade or recovery.
set -u
failed=0
check_file() {
  if [ -e "$1" ]; then echo "OK file $1"; else echo "MISSING file $1"; failed=1; fi
}
check_package() {
  if opkg status "$1" 2>/dev/null | grep -q '^Status: .* installed$'; then
    echo "OK package $1"
  else
    echo "MISSING package $1"
    failed=1
  fi
}
echo "Model: $(cat /tmp/sysinfo/model 2>/dev/null || echo unknown)"
cat /etc/openwrt_release
for p in luci-app-openclash tailscale frpc snmpd ruby ruby-yaml curl; do check_package "$p"; done
for p in \
  /etc/config/openclash \
  /etc/openclash/config/config.yaml \
  /etc/openclash/custom/xia-resilience.rb \
  /etc/openclash/custom/xia-provider-stability.rb \
  /etc/openclash/custom/tailscale-bypass.sh \
  /etc/openclash/core/clash_meta \
  /etc/openclash/group-diagnostics.sh \
  /etc/openclash/node-diagnostics.sh \
  /etc/frp/frpc.toml \
  /etc/tailscale/tailscaled.state; do check_file "$p"; done
grep -Fq '/etc/openclash/group-diagnostics.sh' /etc/crontabs/root 2>/dev/null || { echo 'MISSING hourly diagnostic cron'; failed=1; }
grep -Fq '/etc/openclash/node-diagnostics.sh' /etc/crontabs/root 2>/dev/null || { echo 'MISSING full-node diagnostic cron'; failed=1; }
if iptables -t nat -S 2>/dev/null | grep -Fq 'tailscale-openclash-bypass'; then
  echo 'OK live Tailscale bypass'
else
  echo 'MISSING live Tailscale bypass (restart/check OpenClash after packages are installed)'
  failed=1
fi
if [ "$failed" -eq 0 ]; then echo 'Recovery checks passed'; else echo 'Recovery needs attention'; fi
exit "$failed"
