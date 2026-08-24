# phx-arm authoritative Compose projects

This directory adds authoritative definitions for the standalone running
containers inspected on `phxarm` on 2026-08-24. The existing projects in
`/opt/homepage-phx-arm` and `/data/dsa` remain authoritative and are not
duplicated here.

| Project | Containers |
|---|---|
| `monitoring` | `cadvisor`, `node_exporter` |
| `portainer` | `portainer_agent` |
| `infrastructure` | `nexterm`, `certwarden`, `frps`, `cf-proxy`, `sub-store` |
| `media` | `plex`, `sonarr` |
| `immich` | `immich_postgres`, `immich_machine_learning` |
| `vpn` | `ipsec-vpn-server` |
| `webtop` | `webtop` |

The old stopped `portainer` (Enterprise) and `duplicati` containers are
deliberately excluded. The migration must not start or delete them.

## Capture live secrets and settings

Run the helper while the original containers still exist:

```bash
cd /root/router/maintenance/compose/phx-arm
sudo bash capture-live-env.sh
sudo ls -l /etc/phx-arm-compose
```

It writes root-only files and prints filenames, line counts, and modes only.
Values must never be committed.

## Validation

```bash
for dir in monitoring portainer infrastructure media immich vpn webtop; do
  docker compose -f "$dir/compose.yaml" config --quiet
done

docker compose -f /opt/homepage-phx-arm/compose.yaml config --quiet
cd /data/dsa && docker compose config --quiet
```

## Supervised migration

Take a fresh backup first. Migrate one project at a time and validate health
before continuing:

```bash
/usr/local/bin/backup-agent.sh

docker rm -f cadvisor node_exporter
docker compose -f monitoring/compose.yaml up -d

docker rm -f portainer_agent
docker compose -f portainer/compose.yaml up -d

docker rm -f nexterm certwarden frps cf-proxy sub-store
docker compose -f infrastructure/compose.yaml up -d

docker rm -f plex sonarr
docker compose -f media/compose.yaml up -d

docker rm -f immich_postgres immich_machine_learning
docker compose -f immich/compose.yaml up -d

docker rm -f ipsec-vpn-server
docker compose -f vpn/compose.yaml up -d

docker rm -f webtop
docker compose -f webtop/compose.yaml up -d
```

Validate these generic endpoints:

```text
http://127.0.0.1:3002/
http://127.0.0.1:8180/
http://127.0.0.1:6989/api/health
http://127.0.0.1:4050/certwarden/api/health
http://127.0.0.1:8080/healthz
http://127.0.0.1:9100/metrics
http://127.0.0.1:32400/identity
http://127.0.0.1:3010/
http://127.0.0.1:88/
http://127.0.0.1:3000/
```

Portainer Agent, FRP, the proxy, and IPsec remain covered by their existing
external monitors or protocol-specific checks.

## Maintenance allowlist

After every cutover passes, allowlist the seven directories above plus:

```text
/opt/homepage-phx-arm
/data/dsa
```

The pre-cutover Restic snapshot is `1fb62cb6`. Existing data, secret files,
and the repository change to `backup/install-gdrive-mount.sh` must be
preserved.
