# sjc-tool2 monitoring containers

This is the authoritative deployment definition for the monitoring containers on
`sjc-tool2`. Edit and review this file instead of editing a generated
`docker-autocompose` recovery export.

## Image policy

The Compose defaults intentionally retain the host's existing rolling
`latest` policy so the monthly maintenance agent can pull new releases. The
definitions can be pinned or rolled back without editing `compose.yaml`:

```bash
export CADVISOR_IMAGE='gcr.io/cadvisor/cadvisor@sha256:3de2bd5203120b866d74a9b283b2ffb8ec382fbf9dc321814700c6ea6f44ec57'
export NODE_EXPORTER_IMAGE='quay.io/prometheus/node-exporter@sha256:0f422f62c15f154af8d8572b23d623aebfb10cec73a5c654d18f911f3f9df241'
docker compose up -d
```

Those digests correspond to the configuration inspected on 2026-08-22:

- cAdvisor v0.55.1
- node_exporter v1.11.1

For stricter change control, put explicit version tags or digests in a local
`.env` file and update them through reviewed repository changes.

## Validate

```bash
cd /root/router/maintenance/compose/sjc-tool2
docker compose config --quiet
docker compose config
```

## First migration

The currently running containers were created with `docker run`. During a
supervised maintenance window:

```bash
docker rm -f cadvisor node_exporter
docker compose up -d
docker compose ps
```

The removal is required only for the first migration because Compose cannot
adopt existing containers with the same names. Confirm both metrics endpoints
before adding this directory to `COMPOSE_PROJECT_DIRS`:

```bash
curl --fail http://127.0.0.1:8080/healthz
curl --fail http://127.0.0.1:9100/metrics
```

Then configure:

```bash
COMPOSE_PROJECT_DIRS="/root/router/maintenance/compose/sjc-tool2"
```

Ports 8080 and 9100 remain bound to all host interfaces to match the existing
containers. Restrict them with the host or provider firewall if they are not
intended to be public.
