#!/usr/bin/env bash
# Install the monthly maintenance agent and daily Ubuntu security updates.

set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run this installer as root." >&2; exit 1; }

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
HOST_LABEL="${1:-$(hostname)}"

echo "Installing maintenance-agent for ${HOST_LABEL}..."
apt-get update -qq
apt-get install -y unattended-upgrades curl

install -m 700 "$SCRIPT_DIR/maintenance-agent.sh" /usr/local/bin/maintenance-agent.sh

if [ ! -f /etc/maintenance-agent.conf ]; then
    install -m 600 "$SCRIPT_DIR/maintenance-agent.conf.example" /etc/maintenance-agent.conf
    sed -i "s/^HOST_LABEL=.*/HOST_LABEL=\"${HOST_LABEL}\"/" /etc/maintenance-agent.conf
    echo "Created /etc/maintenance-agent.conf; review it before enabling container updates."
else
    echo "Keeping existing /etc/maintenance-agent.conf."
fi

# Ubuntu archive security updates only. Third-party repositories (including
# LiteSpeed) remain part of the controlled monthly maintenance window.
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

cat > /etc/apt/apt.conf.d/52maintenance-reboot-policy <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
EOF

cat > /etc/systemd/system/maintenance-agent.service <<'EOF'
[Unit]
Description=Backup-gated monthly VPS maintenance
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
Environment=HOME=/root
Environment=XDG_CACHE_HOME=/root/.cache
ExecStart=/usr/local/bin/maintenance-agent.sh
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
TimeoutStartSec=2h
EOF

cat > /etc/systemd/system/maintenance-agent.timer <<'EOF'
[Unit]
Description=Run VPS maintenance on the first Tuesday of each month

[Timer]
OnCalendar=Tue *-*-01..07 03:00:00
RandomizedDelaySec=30m
Persistent=true
Unit=maintenance-agent.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now maintenance-agent.timer

cat <<'EOF'

Maintenance agent installed.

Next steps:
  1. Edit /etc/maintenance-agent.conf.
  2. Add only real, maintained Compose project directories to COMPOSE_PROJECT_DIRS.
  3. Add the public service URLs to HEALTHCHECK_URLS.
  4. Set MAINTENANCE_KUMA_PUSH_URL to a dedicated monthly Push monitor.
  5. Test without waiting for the timer:
       systemctl start maintenance-agent.service
       journalctl -u maintenance-agent.service -f

The timer is active, but an empty COMPOSE_PROJECT_DIRS array means Docker
containers will be audited and left unchanged until you explicitly allow them.
EOF


