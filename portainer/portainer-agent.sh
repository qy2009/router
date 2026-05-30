#!/usr/bin/env bash
set -euo pipefail

PORTAINER_AGENT_DATA_DIR="/data/portainer/agent"
PORTAINER_AGENT_PORT="9001"
PORTAINER_AGENT_IMAGE="portainer/agent:lts"
PORTAINER_AGENT_MEMORY="128m"

sudo mkdir -p "$PORTAINER_AGENT_DATA_DIR"
sudo chown -R $(id -u):$(id -g) /data/portainer

docker rm -f portainer >/dev/null 2>&1 || true
docker rm -f portainer_agent >/dev/null 2>&1 || true

docker run -d \
  --name portainer_agent \
  --restart unless-stopped \
  --memory="${PORTAINER_AGENT_MEMORY}" \
  -p ${PORTAINER_AGENT_PORT}:9001 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /var/lib/docker/volumes:/var/lib/docker/volumes \
  -v ${PORTAINER_AGENT_DATA_DIR}:/data \
  ${PORTAINER_AGENT_IMAGE}

echo "Portainer Agent deployed."
echo "Agent endpoint: https://THIS_HOST_IP:${PORTAINER_AGENT_PORT}"
echo "Data path: ${PORTAINER_AGENT_DATA_DIR}"
