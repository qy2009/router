# sjc-tool authoritative Compose projects

These projects cover all seven containers observed before migration:

- `monitoring/`: Alertmanager, Blackbox Exporter, Grafana, Prometheus, and SNMP Exporter
- `portainer/`: Portainer CE
- `uptime-kuma/`: Uptime Kuma, migrated from `/data/uptime-kuma/docker-compose.yml`

The definitions preserve live images, ports, bind mounts, users, commands,
restart policies, bridge networking, and Uptime Kuma's memory limit. No
operator-supplied environment overrides were present.

## Validate

```bash
cd /root/router/maintenance/compose/sjc-tool
sudo docker compose -f monitoring/compose.yaml config --quiet
sudo docker compose -f portainer/compose.yaml config --quiet
sudo docker compose -f uptime-kuma/compose.yaml config --quiet
```

## Local health URLs

```text
http://127.0.0.1:9090/-/healthy
http://127.0.0.1:9093/-/healthy
http://127.0.0.1:9115/metrics
http://127.0.0.1:9116/metrics
http://127.0.0.1:3000/api/health
http://127.0.0.1:3001/
```

Portainer CE uses a self-signed HTTPS listener bound to
`127.0.0.1:9444`; validate its container state and logs locally rather than
adding it to the maintenance agent's curl checks.

## Supervised cutover

Take a fresh backup first. Migrate monitoring, Portainer, and Uptime Kuma one
project at a time, validating each before continuing. Add the three directories
to `COMPOSE_PROJECT_DIRS` only after the complete cutover succeeds.
