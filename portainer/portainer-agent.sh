#!/usr/bin/env bash
set -euo pipefail

PORTAINER_AGENT_DATA_DIR="/data/portainer/agent"
PORTAINER_AGENT_PORT="9001"
PORTAINER_AGENT_IMAGE="portainer/agent:lts"
PORTAINER_AGENT_MEMORY="128m"

install_docker_if_missing() {
  if command -v docker >/dev/null 2>&1; then
    echo "Docker already installed: $(docker --version)"
    return
  fi

  echo "Docker not found. Installing Docker..."
  sudo apt update
  sudo apt install -y ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo     "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" |     sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt update
  sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo systemctl enable --now docker
  sudo usermod -aG docker "$USER" || true
  echo "Docker installed. You may need to log out and back in for docker group changes to apply."
}

install_docker_if_missing

sudo mkdir -p "$PORTAINER_AGENT_DATA_DIR"
sudo chown -R $(id -u):$(id -g) /data/portainer

docker rm -f portainer >/dev/null 2>&1 || true
docker rm -f portainer_agent >/dev/null 2>&1 || true

docker run -d   --name portainer_agent   --restart unless-stopped   --memory="${PORTAINER_AGENT_MEMORY}"   -p ${PORTAINER_AGENT_PORT}:9001   -v /var/run/docker.sock:/var/run/docker.sock   -v /var/lib/docker/volumes:/var/lib/docker/volumes   -v ${PORTAINER_AGENT_DATA_DIR}:/data   ${PORTAINER_AGENT_IMAGE}

echo "Portainer Agent deployed."
echo "Agent endpoint: https://THIS_HOST_IP:${PORTAINER_AGENT_PORT}"
echo "Data path: ${PORTAINER_AGENT_DATA_DIR}"
