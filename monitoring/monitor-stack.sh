#!/usr/bin/env bash
set -euo pipefail

MONITOR_DATA_DIR="/data/monitoring/prometheus"
PROMETHEUS_PORT="9090"
GRAFANA_PORT="3000"
ALERTMANAGER_PORT="9093"
BLACKBOX_PORT="9115"
PROMETHEUS_IMAGE="prom/prometheus:v3.5.0"
GRAFANA_IMAGE="grafana/grafana-oss:latest"
ALERTMANAGER_IMAGE="prom/alertmanager:v0.28.0"
BLACKBOX_IMAGE="prom/blackbox-exporter:v0.27.0"

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

sudo mkdir -p "$MONITOR_DATA_DIR" /data/monitoring/grafana /data/monitoring/alertmanager /data/monitoring/blackbox
sudo chown -R $(id -u):$(id -g) /data/monitoring

cat > /tmp/prometheus.yml <<'YAML'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - /etc/prometheus/rules/*.yml

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']

  - job_name: blackbox
    metrics_path: /probe
    params:
      module: [http_2xx]
    static_configs:
      - targets:
        - https://example.com
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox:9115

  - job_name: node_exporter
    static_configs:
      - targets:
        - PHX-ARM1:9100
        - SJC-AMD11:9100
        - ZRH-DEBIAN5:9100
        - ZRH-DEBIAN6:9100
        - PHX-WP7:9100
        - ZRH-ARM8:9100
        - SJC-DEBIAN11:9100
        - UNRAID:9100

  - job_name: windows_exporter
    static_configs:
      - targets:
        - SJC-WIN11:9182
        - PHX-WIN7:9182
        - ZRH-WIN7:9182

  - job_name: cadvisor
    static_configs:
      - targets:
        - PHX-ARM1:8080
        - ZRH-ARM8:8080
        - PHX-WP7:8080
YAML

cat > /tmp/alertmanager.yml <<'YAML'
global:
  resolve_timeout: 5m
route:
  receiver: default
receivers:
  - name: default
YAML

cat > /tmp/blackbox.yml <<'YAML'
modules:
  http_2xx:
    prober: http
    timeout: 5s
    http:
      valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
      valid_status_codes: []
      method: GET
      no_follow_redirects: false
      preferred_ip_protocol: "ip4"
YAML

docker rm -f prometheus grafana alertmanager blackbox >/dev/null 2>&1 || true

docker run -d --name blackbox --restart unless-stopped -p 9115:9115 -v /tmp/blackbox.yml:/etc/blackbox_exporter/config.yml:ro $BLACKBOX_IMAGE --config.file=/etc/blackbox_exporter/config.yml

docker run -d --name alertmanager --restart unless-stopped -p 9093:9093 -v /tmp/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro $ALERTMANAGER_IMAGE --config.file=/etc/alertmanager/alertmanager.yml

docker run -d --name prometheus --restart unless-stopped -p 9090:9090 -v /tmp/prometheus.yml:/etc/prometheus/prometheus.yml:ro -v $MONITOR_DATA_DIR:/prometheus -v /data/monitoring/rules:/etc/prometheus/rules $PROMETHEUS_IMAGE --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/prometheus

docker run -d --name grafana --restart unless-stopped -p 3000:3000 -v /data/monitoring/grafana:/var/lib/grafana -e GF_SECURITY_ADMIN_USER=admin -e GF_SECURITY_ADMIN_PASSWORD=admin $GRAFANA_IMAGE

echo "Monitoring stack deployed. Prometheus on :$PROMETHEUS_PORT, Grafana on :$GRAFANA_PORT"
