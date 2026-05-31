#!/usr/bin/env bash
set -euo pipefail

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

docker rm -f node_exporter cadvisor >/dev/null 2>&1 || true

docker run -d --name node_exporter --restart unless-stopped -p 9100:9100 -v /:/host:ro,rslave quay.io/prometheus/node-exporter:latest --path.rootfs=/host

docker run -d --name cadvisor --restart unless-stopped -p 8080:8080 --volume=/:/rootfs:ro --volume=/var/run:/var/run:ro --volume=/sys:/sys:ro --volume=/var/lib/docker/:/var/lib/docker:ro --device=/dev/kmsg gcr.io/cadvisor/cadvisor:latest

echo "Node exporter on :9100, cAdvisor on :8080"
