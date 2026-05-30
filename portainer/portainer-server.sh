#!/usr/bin/env bash
set -euo pipefail

PORTAINER_DATA_DIR="/data/portainer/server"
PORTAIER_PORT="9443"
PORTAINER_TUNNEL_PORT="8000"
PORTAINER_IMAGE="portainer/portainer-ce:lts"

sudo mkdir -p "$PORTAINER_DATA_DIR"
sudo chown -R $(id -u):$(id -g) /data/portainer

docker volume rm portainer_data >/dev/null 2>&1 || true
docker rm -f portainer >/dev/null 2>&1 || true

docker run -d \
  --name portainer \
  --restart unless-stopped \
  -p ${PORTAINER_PORT}:9443 \
  -p ${PORTAINER_TUNNEL_PORT}:8000 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v ${PORTAINER_DATA_DIR}:/data \
  ${PORTAINER_IMAGE} \
  --snapshot-interval=10m

echo "Portainer Server deployed."
echo "URL: https://YOUR_SERVER_IP:${PORTAINER_PORT}"
echo "Data path: ${PORTAINER_DATA_DIR}"
