#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-}"

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

if [[ -z "$MODE" ]]; then
    echo "Usage: $0 server|agent"
    echo ""
    echo "Modes:"
    echo "  server  - Install Portainer Server (main UI) on your spare VPS"
    echo "  agent   - Install Portainer Agent on Docker hosts (PHX/ZRH)"
    exit 1
fi

install_docker_if_missing

case "$MODE" in
    server)
        echo "Installing Portainer Server..."
        PORTAINER_DATA_DIR="/data/portainer/server"
        PORTAINER_PORT="9443"
        PORTAINER_TUNNEL_PORT="8000"
        PORTAINER_IMAGE="portainer/portainer-ce:lts"

        sudo mkdir -p "$PORTAINER_DATA_DIR"
        sudo chown -R $(id -u):$(id -g) /data/portainer

        docker volume rm portainer_data >/dev/null 2>&1 || true
        docker rm -f portainer >/dev/null 2>&1 || true

        docker run -d           --name portainer           --restart unless-stopped           -p ${PORTAINER_PORT}:9443           -p ${PORTAINER_TUNNEL_PORT}:8000           -v /var/run/docker.sock:/var/run/docker.sock           -v ${PORTAINER_DATA_DIR}:/data           ${PORTAINER_IMAGE}           --snapshot-interval=10m

        echo ""
        echo "✅ Portainer Server deployed."
        echo "URL: https://YOUR_SERVER_IP:${PORTAINER_PORT}"
        echo "Data path: ${PORTAINER_DATA_DIR}"
        echo ""
        echo "Next steps:"
        echo "1. Open https://YOUR_SERVER_IP:${PORTAINER_PORT} in your browser"
        echo "2. Create admin account"
        echo "3. Add your Docker hosts as Agent endpoints:"
        echo "   - Environment URL: http://PHX_IP:9001"
        echo "   - Environment URL: http://ZRH_IP:9001"
        ;;
    agent)
        echo "Installing Portainer Agent..."
        PORTAINER_AGENT_DATA_DIR="/data/portainer/agent"
        PORTAINER_AGENT_PORT="9001"
        PORTAINER_AGENT_IMAGE="portainer/agent:lts"
        PORTAINER_AGENT_MEMORY="128m"

        sudo mkdir -p "$PORTAINER_AGENT_DATA_DIR"
        sudo chown -R $(id -u):$(id -g) /data/portainer

        docker rm -f portainer >/dev/null 2>&1 || true
        docker rm -f portainer_agent >/dev/null 2>&1 || true

        docker run -d           --name portainer_agent           --restart unless-stopped           --memory="${PORTAINER_AGENT_MEMORY}"           -p ${PORTAINER_AGENT_PORT}:9001           -v /var/run/docker.sock:/var/run/docker.sock           -v /var/lib/docker/volumes:/var/lib/docker/volumes           -v ${PORTAINER_AGENT_DATA_DIR}:/data           ${PORTAINER_AGENT_IMAGE}

        echo ""
        echo "✅ Portainer Agent deployed."
        echo "Agent endpoint: https://THIS_HOST_IP:${PORTAINER_AGENT_PORT}"
        echo "Data path: ${PORTAINER_AGENT_DATA_DIR}"
        echo ""
        echo "Next steps:"
        echo "1. In Portainer Server UI → Environments → Add environment"
        echo "2. Choose: Agent"
        echo "3. Endpoint URL: http://THIS_HOST_IP:${PORTAINER_AGENT_PORT}"
        echo "4. Name it (e.g., PHX-Docker or ZRH-Docker)"
        ;;
    *)
        echo "Unknown mode: $MODE"
        echo "Usage: $0 server|agent"
        exit 1
        ;;
esac
