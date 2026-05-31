#!/usr/bin/env bash
set -euo pipefail
PROM_CONTAINER="prometheus"
if ! docker ps --format '{{.Names}}' | grep -qx "$PROM_CONTAINER"; then
  echo "Prometheus container '$PROM_CONTAINER' is not running."
  exit 1
fi
if docker exec "$PROM_CONTAINER" wget -qO- http://127.0.0.1:9090/-/reload >/dev/null 2>&1; then
  echo "Prometheus reloaded successfully."
else
  echo "Reload failed. Check config with: docker logs prometheus"
  exit 1
fi
