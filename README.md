 wget --no-check-certificate -O /tmp/myrouter.sh https://raw.githubusercontent.com/qy2009/iptv//main/myrouter.sh && chmod +x /tmp/myrouter.sh && /tmp/myrouter.sh

curl -fsSL https://raw.githubusercontent.com/qy2009/router/main/vps-setup -o vps-setup.sh && sudo bash vps-setup.sh

portainer server mode
bash <(curl -fsSL "https://raw.githubusercontent.com/qy2009/router/main/portainer/portainer-install.sh?$(date +%s)") server
client mode
bash <(curl -fsSL "https://raw.githubusercontent.com/qy2009/router/main/portainer/portainer-install.sh?$(date +%s)") agent

monitoring stack
bash <(curl -fsSL "https://raw.githubusercontent.com/qy2009/router/main/monitoring/monitor-stack.sh?$(date +%s)")

node
bash <(curl -fsSL "https://raw.githubusercontent.com/qy2009/router/main/monitoring/monitor-node.sh?$(date +%s)")

windows
curl.exe -L "https://raw.githubusercontent.com/qy2009/router/main/monitoring/windows-exporter-install.bat?%RANDOM%" -o windows-exporter-install.bat
windows-exporter-install.bat

monitoring refresh
bash <(curl -fsSL "https://raw.githubusercontent.com/qy2009/router/main/monitoring/reload-prometheus.sh?$(date +%s)")
