#!/usr/bin/env bash
set -euo pipefail

PORTAINER_DATA_DIR="/data/portainer/server"
PORTAINER_PORT="9443"
PORTAINER_TUNNEL_PORT="8000"
PORTAINER_IMAGE="portainer/portainer-ce:lts"

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

sudo mkdir -p "$PORTAINER_DATA_DIR"
sudo chown -R $(id -u):$(id -g) /data/portainer

docker volume rm portainer_data >/dev/null 2>&1 || true
docker rm -f portainer >/dev/null 2>&1 || true

docker run -d   --name portainer   --restart unless-stopped   -p ${PORTAINER_PORT}:9443   -p ${PORTAINER_TUNNEL_PORT}:8000   -v /var/run/docker.sock:/var/run/docker.sock   -v ${PORTAINER_DATA_DIR}:/data   ${PORTAINER_IMAGE}   --snapshot-interval=10m

echo "Portainer Server deployed."
echo "URL: https://YOUR_SERVER_IP:${PORTAINER_PORT}"
echo "Data path: ${PORTAINER_DATA_DIR}"
