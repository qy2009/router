# Unraid Alloy log agent

Collects Docker logs and Unraid host syslog from `rui-server`, then sends them
to Loki on phx-casa over Tailscale. Persistent state is stored in
`/mnt/user/appdata/alloy`.

```bash
mkdir -p /mnt/user/appdata/alloy
docker compose config --quiet
docker compose up -d
```

Deployment is pending until Tailscale SSH or the saved Nexterm connection for
`rui-server` is authorized.
