#!/usr/bin/env bash
set -euo pipefail

MONITOR_DATA_DIR="/data/monitoring"
PROMETHEUS_PORT="9090"
GRAFANA_PORT="3000"
ALERTMANAGER_PORT="9093"
BLACKBOX_PORT="9115"
PROMETHEUS_IMAGE="prom/prometheus:v3.5.0"
GRAFANA_IMAGE="grafana/grafana-oss:latest"
ALERTMANAGER_IMAGE="prom/alertmanager:v0.28.0"
BLACKBOX_IMAGE="prom/blackbox-exporter:v0.27.0"
PROM_UID="65534"
PROM_GID="65534"

install_docker_if_missing() {
  if command -v docker >/dev/null 2>&1; then return; fi
  sudo apt update
  sudo apt install -y ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt update
  sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo systemctl enable --now docker
}

install_docker_if_missing

sudo mkdir -p \
  "$MONITOR_DATA_DIR/prometheus/config" \
  "$MONITOR_DATA_DIR/prometheus/data" \
  "$MONITOR_DATA_DIR/grafana" \
  "$MONITOR_DATA_DIR/alertmanager" \
  "$MONITOR_DATA_DIR/blackbox" \
  "$MONITOR_DATA_DIR/targets" \
  "$MONITOR_DATA_DIR/rules"

sudo chown -R $(id -u):$(id -g) "$MONITOR_DATA_DIR"
sudo chown -R ${PROM_UID}:${PROM_GID} "$MONITOR_DATA_DIR/prometheus/data"
sudo chmod 775 "$MONITOR_DATA_DIR/prometheus/data"

cat > "$MONITOR_DATA_DIR/prometheus/config/prometheus.yml" <<'YAML'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - /etc/prometheus/rules/*.yml

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']

  - job_name: blackbox-http
    metrics_path: /probe
    params:
      module: [http_2xx]
    file_sd_configs:
      - files:
          - /etc/prometheus/targets/websites.yml
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox:9115

  - job_name: linux-node
    file_sd_configs:
      - files:
          - /etc/prometheus/targets/linux.yml

  - job_name: windows-node
    file_sd_configs:
      - files:
          - /etc/prometheus/targets/windows.yml

  - job_name: docker-cadvisor
    file_sd_configs:
      - files:
          - /etc/prometheus/targets/cadvisor.yml
YAML

cat > "$MONITOR_DATA_DIR/alertmanager/alertmanager.yml" <<'YAML'
global:
  resolve_timeout: 5m
route:
  receiver: default
receivers:
  - name: default
YAML

cat > "$MONITOR_DATA_DIR/blackbox/blackbox.yml" <<'YAML'
modules:
  http_2xx:
    prober: http
    timeout: 5s
    http:
      preferred_ip_protocol: "ip4"
YAML

cat > "$MONITOR_DATA_DIR/targets/linux.yml" <<'YAML'
- targets:
  - PHX-ARM1:9100
  - ZRH-DEBIAN5:9100
  - ZRH-DEBIAN6:9100
  - ZRH-ARM8:9100
  - SJC-DEBIAN11:9100
  labels:
    job: linux-node
YAML

cat > "$MONITOR_DATA_DIR/targets/windows.yml" <<'YAML'
- targets:
  - SJC-WIN11:9182
  - PHX-WIN7:9182
  - ZRH-WIN7:9182
  labels:
    job: windows-node
YAML

cat > "$MONITOR_DATA_DIR/targets/cadvisor.yml" <<'YAML'
- targets:
  - PHX-ARM1:8080
  - ZRH-ARM8:8080
  - PHX-WP7:8080
  labels:
    job: docker-cadvisor
YAML

cat > "$MONITOR_DATA_DIR/targets/websites.yml" <<'YAML'
- targets:
  - https://wordpress1.example.com
  - https://wordpress2.example.com
  labels:
    job: website
YAML

docker rm -f prometheus grafana alertmanager blackbox >/dev/null 2>&1 || true

docker run -d --name blackbox --restart unless-stopped \
  -p 9115:9115 \
  -v "$MONITOR_DATA_DIR/blackbox/blackbox.yml:/etc/blackbox_exporter/config.yml:ro" \
  $BLACKBOX_IMAGE --config.file=/etc/blackbox_exporter/config.yml

docker run -d --name alertmanager --restart unless-stopped \
  -p 9093:9093 \
  -v "$MONITOR_DATA_DIR/alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro" \
  $ALERTMANAGER_IMAGE --config.file=/etc/alertmanager/alertmanager.yml

docker run -d --name prometheus --restart unless-stopped \
  --user ${PROM_UID}:${PROM_GID} \
  -p 9090:9090 \
  -v "$MONITOR_DATA_DIR/prometheus/config/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
  -v "$MONITOR_DATA_DIR/targets:/etc/prometheus/targets:ro" \
  -v "$MONITOR_DATA_DIR/rules:/etc/prometheus/rules:ro" \
  -v "$MONITOR_DATA_DIR/prometheus/data:/prometheus" \
  $PROMETHEUS_IMAGE \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/prometheus

docker run -d --name grafana --restart unless-stopped \
  -p 3000:3000 \
  -v "$MONITOR_DATA_DIR/grafana:/var/lib/grafana" \
  -e GF_SECURITY_ADMIN_USER=admin \
  -e GF_SECURITY_ADMIN_PASSWORD=admin \
  $GRAFANA_IMAGE

echo "Monitoring stack deployed."
echo "Prometheus: http://SERVER_IP:$PROMETHEUS_PORT"
echo "Grafana: http://SERVER_IP:$GRAFANA_PORT"
echo "Prometheus data dir: $MONITOR_DATA_DIR/prometheus/data owned by ${PROM_UID}:${PROM_GID}"
