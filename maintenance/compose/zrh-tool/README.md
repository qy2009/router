# zrh-tool authoritative Compose projects

These projects reproduce the five containers observed on zrh-tool before its
supervised migration:

- `monitoring/`: Alertmanager, Blackbox Exporter, Grafana, and Prometheus
- `portainer/`: Portainer Agent

The definitions preserve the live images, ports, bind mounts, users, commands,
restart policies, network mode, and bind propagation. Grafana's two
operator-supplied security overrides are stored only in a root-owned env file.

## Prepare and validate

```bash
cd /root/router/maintenance/compose/zrh-tool
sudo bash capture-live-env.sh
sudo docker compose -f monitoring/compose.yaml config --quiet
sudo docker compose -f portainer/compose.yaml config --quiet
```

The capture helper never prints environment values and writes
`/etc/zrh-tool-compose/grafana.env` with mode `0600`.

## Health checks

Use these local checks during cutover and in `/etc/maintenance-agent.conf`:

```text
http://127.0.0.1:9090/-/healthy
http://127.0.0.1:9093/-/healthy
http://127.0.0.1:9115/metrics
http://127.0.0.1:3000/api/health
```

Portainer Agent's `/ping` endpoint requires Portainer protocol headers, so
container state and logs are used for its local validation.

## Supervised cutover

Take a fresh backup first. Then migrate one project at a time by removing only
the matching standalone containers and running `docker compose up -d`.
Validate every service and URL before proceeding. Add both project directories
to `COMPOSE_PROJECT_DIRS` only after the complete cutover succeeds.
