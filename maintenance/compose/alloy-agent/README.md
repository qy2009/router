# Alloy VPS log agent

This reusable agent sends Docker logs, the systemd journal, and the standard
backup and maintenance agent logs to the central Loki instance on phx-casa
over Tailscale.

Copy `.env.example` to `.env`, set a stable host label, and start the service:

```bash
cp .env.example .env
docker compose config --quiet
docker compose up -d
```

The current Linux VPS labels are `phx-arm`, `zrh-arm`, `zrh-tool`,
`sjc-tool`, `sjc-tool2`, and `digital-ocean`. Agent state is stored in
`/data/monitoring/alloy`. The central endpoint is intentionally reachable
only through Tailscale.
