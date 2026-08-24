# DigitalOcean authoritative Compose projects

These projects reproduce the three standalone containers inspected on `xblog`
(the DigitalOcean VPS) on 2026-08-24.

| Project | Containers |
|---|---|
| `monitoring` | `cadvisor`, `node_exporter` |
| `portainer` | `portainer_agent` |

OpenLiteSpeed is intentionally not containerized. It remains managed by the
native `lsws.service` and the maintenance agent's controlled monthly system
update.

## Validation

```bash
cd /root/router/maintenance/compose/digital-ocean
docker compose -f monitoring/compose.yaml config --quiet
docker compose -f portainer/compose.yaml config --quiet
```

## Supervised first migration

Take a fresh backup first, then migrate one project at a time:

```bash
/usr/local/bin/backup-agent.sh

docker rm -f cadvisor node_exporter
docker compose -f monitoring/compose.yaml up -d

docker rm -f portainer_agent
docker compose -f portainer/compose.yaml up -d
```

Validate these endpoints before adding the project directories to the
maintenance allowlist:

```text
http://127.0.0.1:8080/healthz
http://127.0.0.1:9100/metrics
http://127.0.0.1:8088/
https://bootedray.com/
```

Portainer Agent uses TLS with its own certificate on port 9001, so it is
validated by container state and the existing external monitor rather than the
maintenance agent's generic certificate-validating HTTP GET.

## Image policy and rollback

The exporter definitions preserve their existing rolling `latest` tags for
the requested automated-update policy. Portainer Agent remains pinned to the
live `2.39.2` tag. Before migration, the tested image digests were:

- Portainer Agent: `portainer/agent@sha256:dc0e8285f8b4c105c3237f1cc0022f92dd265c53ced5f53b9ce7c9741144e879`
- cAdvisor: `gcr.io/cadvisor/cadvisor@sha256:3de2bd5203120b866d74a9b283b2ffb8ec382fbf9dc321814700c6ea6f44ec57`
- Node Exporter: `quay.io/prometheus/node-exporter@sha256:0f422f62c15f154af8d8572b23d623aebfb10cec73a5c654d18f911f3f9df241`

To roll back a container image, temporarily replace its tag with the recorded
repository digest and run `docker compose up -d`. The pre-cutover Restic
snapshot is `6294c333`.

## Maintenance allowlist

After the supervised cutover succeeds, add these directories to
`COMPOSE_PROJECT_DIRS`:

```text
/root/router/maintenance/compose/digital-ocean/monitoring
/root/router/maintenance/compose/digital-ocean/portainer
```
