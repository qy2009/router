# phx-casa authoritative Compose project

This project reproduces the single running standalone container inspected on
`phx-casa` on 2026-08-24.

| Project | Container |
|---|---|
| `portainer` | `portainer_agent` |

The stopped `big-bear-brave`, `firefly`, and `big-bear-chromium`
containers are deliberately excluded. The migration must not start or delete
them.

## Validation and supervised migration

```bash
cd /root/router/maintenance/compose/phx-casa
docker compose -f portainer/compose.yaml config --quiet

/usr/local/bin/backup-agent.sh
docker rm -f portainer_agent
docker compose -f portainer/compose.yaml up -d
```

Portainer Agent uses TLS with its own certificate on port 9001. Validate
`https://127.0.0.1:9001/ping` with a protocol-aware check and the existing
external monitor; do not add its self-signed URL to the maintenance agent's
generic certificate-validating HTTP list.

The tested image digest before migration was
`portainer/agent@sha256:dc0e8285f8b4c105c3237f1cc0022f92dd265c53ced5f53b9ce7c9741144e879`.
The pre-cutover Restic snapshot is `b0a4a7ce`.

After validation, allowlist:

```text
/root/router/maintenance/compose/phx-casa/portainer
```
