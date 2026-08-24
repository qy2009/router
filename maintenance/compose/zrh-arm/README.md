# zrh-arm authoritative Compose projects

These six projects reproduce the nine standalone containers inspected on
`zrh-arm` on 2026-08-23. They are intentionally separated by function so one
image update does not unnecessarily recreate unrelated services.

| Project | Containers |
|---|---|
| `monitoring` | `cadvisor`, `node_exporter` |
| `portainer` | `portainer_edge_agent`, `portainer_agent` |
| `plex` | `plex` |
| `vpn` | `ipsec-vpn-server`, `wg-easy` |
| `webtop` | `webtop` |
| `rclone` | `Rclone-backup` |

## Secrets and environment files

Compose references root-only files in `/etc/zrh-arm-compose`. Run the capture
helper while the original containers still exist:

```bash
cd /root/router/maintenance/compose/zrh-arm
sudo bash capture-live-env.sh
sudo ls -l /etc/zrh-arm-compose
```

The helper prints filenames and counts only. It does not print credential
values. Back up `/etc/zrh-arm-compose`, but never commit it.

## Validation

```bash
for dir in monitoring portainer plex vpn webtop rclone; do
  docker compose -f "$dir/compose.yaml" config --quiet
done
```

## Supervised first migration

Take a fresh backup first. Migrate one project at a time so failures remain
isolated:

```bash
/usr/local/bin/backup-agent.sh

docker rm -f cadvisor node_exporter
docker compose -f monitoring/compose.yaml up -d

docker rm -f portainer_edge_agent portainer_agent
docker compose -f portainer/compose.yaml up -d

docker rm -f plex
docker compose -f plex/compose.yaml up -d

docker rm -f ipsec-vpn-server wg-easy
docker compose -f vpn/compose.yaml up -d

docker rm -f webtop
docker compose -f webtop/compose.yaml up -d

docker rm -f Rclone-backup
docker compose -f rclone/compose.yaml up -d
```

Verify all Uptime Kuma monitors and the local maintenance endpoints before
allowlisting the projects:

```text
http://127.0.0.1:8080/healthz
http://127.0.0.1:9100/metrics
http://127.0.0.1:32400/identity
http://127.0.0.1:51821/
http://127.0.0.1:3000/
```

The Portainer Edge agent is outbound-only. Portainer Agent port 9001 returns
HTTP 400 without its protocol headers, so both agents are validated by
container state and the external Portainer/Uptime monitor rather than a generic
HTTP GET.

## Image policy and rollback

The definitions preserve the live tags, including rolling tags, because that is
the requested automated-update policy. Portainer Edge remains pinned to
`2.39.2`. Before the first migration, the tested image digests were:

- Portainer Agent: `sha256:dc0e8285f8b4c105c3237f1cc0022f92dd265c53ced5f53b9ce7c9741144e879`
- cAdvisor: `sha256:3de2bd5203120b866d74a9b283b2ffb8ec382fbf9dc321814700c6ea6f44ec57`
- node_exporter: `sha256:0f422f62c15f154af8d8572b23d623aebfb10cec73a5c654d18f911f3f9df241`
- Plex: `sha256:b19a5e34c6f8dd42abf88556b8aa5c8987c0c34820aaeaa320a02d8c17fdaab3`
- IPsec VPN: `sha256:77425db2eefa5dd67cbc1e23b735ef7e1b7e2bafb87e2d041aa398479ec827fd`
- wg-easy: `sha256:5f26407fd2ede54df76d63304ef184576a6c1bb73f934a58a11abdd852fab549`
- Webtop: `sha256:9f64fa2645c81f5a2241b915ce8afe5813fb0ec3e56dac5cd3602cd0c42ff7c7`
- rclone: `sha256:06604170ea5533ca1c141cee06c283e2a3966c1f9ef9b8d15b4ca3efa59de530`

To roll back, replace a service's image tag temporarily with its full repository
digest and run `docker compose up -d`.

## Maintenance allowlist

After the supervised migration succeeds, add all six absolute directories to
`COMPOSE_PROJECT_DIRS` in `/etc/maintenance-agent.conf`. Do not allowlist
these projects before the original containers have been migrated.
