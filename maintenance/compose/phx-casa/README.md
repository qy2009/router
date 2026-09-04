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


## Central logging

Grafana uses the Loki data source on phx-casa. Loki listens on
`172.17.0.1:3100` for local containers and `100.111.111.118:3100` for
Tailscale-connected Alloy agents. It is not published on the public interface.

Alloy collects local Docker logs, the systemd journal, and
`/var/log/backup-agent.log` plus `/var/log/maintenance-agent.log`.

Router syslog uses Tailscale-only UDP listeners:

- `100.111.111.118:1514/udp`: `xia-router`
- `100.111.111.118:1515/udp`: `travel-router` (enable when reachable)
- `100.111.111.118:1516/udp`: `home-router`

OpenWrt configuration:

```sh
uci set system.@system[0].log_ip='100.111.111.118'
uci set system.@system[0].log_port='1514'
uci set system.@system[0].log_proto='udp'
uci set system.@system[0].log_remote='1'
uci commit system
/etc/init.d/log restart
```

Useful LogQL selectors are `{job="script"}` and
`{job="router-syslog", host="xia-router"}`.
