# Automated VPS maintenance

This directory adds backup-gated operating-system, Docker Compose, and
OpenLiteSpeed maintenance to the existing VPS backup system.

## Policy

- Ubuntu archive security updates run daily through `unattended-upgrades`.
- Normal package, Docker Engine, OpenLiteSpeed, and allowed container-image
  updates run on the first Tuesday of each month at 03:00, with up to 30
  minutes of randomized delay per host.
- Package upgrades use `apt-get upgrade --with-new-pkgs`, allowing security
  kernel meta-packages to install their newly versioned dependencies without
  permitting the package removals that `full-upgrade` can perform.
- A fresh `/usr/local/bin/backup-agent.sh` run must succeed before anything is
  updated. A failed backup aborts maintenance.
- Reboots happen only when `/var/run/reboot-required` exists and all configured
  health checks have passed.
- Distribution release upgrades (`do-release-upgrade`) are never automated.

The existing weekly backup runs Sunday at 03:00. The monthly job still creates
another snapshot immediately before maintenance so rollback data matches the
state that was changed.

## Why Docker projects are allowlisted

The repository currently contains both Docker Compose deployments and
containers created directly with `docker run`. Compose can safely pull an image
and recreate a service from its authoritative configuration. A generic script
cannot safely reconstruct a standalone container if any port, mount, secret,
environment variable, device, capability, or network setting is missed.

`maintenance-agent.sh` therefore:

1. Updates only directories explicitly listed in `COMPOSE_PROJECT_DIRS`.
2. Validates each Compose file before pulling.
3. Updates one project at a time.
4. Waits for all containers that were previously running to become running and,
   when defined, healthy.
5. Reports standalone containers but does not replace them.

Do not allowlist the Compose recovery exports created by
`backup/backup-agent.sh` and `docker-autocompose`. Migrate a standalone service
to a maintained Compose project first, then allowlist that project.

Pin stateful services such as MariaDB and PostgreSQL to a supported major
version (`mariadb:11.4`, for example), never `latest`. An image update is not a
database-major-version migration plan.

## Install

On each VPS, from the repository checkout:

```bash
cd maintenance
sudo bash install-maintenance-agent.sh
sudoedit /etc/maintenance-agent.conf
```

For the DigitalOcean WordPress/OpenLiteSpeed host, install the same files. The
agent detects the `openlitespeed` APT package, updates it in the monthly window,
validates its configuration, confirms `lsws` is active, and checks any site URLs
you put in `HEALTHCHECK_URLS`. Its existing WordPress backup agent remains the
mandatory pre-update backup.

## Configure monitoring

Create one Uptime Kuma Push monitor per host, separate from its backup monitor.
Use a monthly interval with enough grace for the randomized timer delay, then
set its URL as `MAINTENANCE_KUMA_PUSH_URL`.

The agent also reuses `PUSHOVER_USER` and `PUSHOVER_TOKEN` from
`/etc/backup-agent/secrets.env`.

## Test and operate

Validate the timer and configuration:

```bash
systemctl list-timers maintenance-agent.timer
systemd-analyze calendar 'Tue *-*-01..07 03:00:00'
bash -n /usr/local/bin/maintenance-agent.sh
```

Run a supervised first maintenance:

```bash
systemctl start maintenance-agent.service
journalctl -u maintenance-agent.service -f
tail -f /var/log/maintenance-agent.log
```

To defer one run:

```bash
systemctl stop maintenance-agent.timer
# Re-enable afterward:
systemctl enable --now maintenance-agent.timer
```

If a reboot was scheduled but should not occur, cancel it during the configured
delay:

```bash
shutdown -c
```

## Rollback

If a package or service update fails, the agent stops and sends failure status;
it does not prune old Docker images. Use the fresh restic snapshot and
`backup/RECOVERY.md` for data/config recovery. For the DigitalOcean host, a
Droplet snapshot or automatic backup provides the fastest whole-machine
rollback when available.

