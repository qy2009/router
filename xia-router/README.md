# xia-router backup and recovery

This setup was verified on the GL.iNet GL-MT2500 (`Xia-Router`), OpenWrt
`21.02-SNAPSHOT`, `aarch64_cortex-a53`, using `opkg`. The active router is
`100.111.111.119` on Tailscale. PHX-ARM pulls a backup over the private SSH
path; the router does not need a key that can log into PHX.

## What is running

- PHX-ARM: `/usr/local/sbin/backup-from-phx.sh` runs weekly, Sunday at 04:15
  Los Angeles time. It writes a verified backup to
  `/data/router-backups/xia-router/YYYYMMDDTHHMMSSZ/`, then copies and
  verifies the same files at `/gdrive/Backup/xia-router/YYYYMMDDTHHMMSSZ/`.
  The local `latest` link and Google Drive `latest.txt` are updated only after
  both copies pass SHA-256 checks. The latest 14 local backups are retained.
- Uptime Kuma `xia-router-backup` is a Push monitor with the existing Pushover
  notification and an eight-day heartbeat window. The PHX job pushes `up`
  after both copies verify and attempts to push `down` on a failed run. Its
  token belongs in `/etc/xia-router-backup-monitor.env` (mode 600), never Git.
- PHX-ARM: `/usr/local/sbin/verify-backup.sh /data/router-backups/xia-router/latest`
  checks hashes, gzip/tar integrity, and critical paths without changing the
  router.
- PHX-ARM: `/usr/local/sbin/stage-restore-from-phx.sh root@TARGET` checks the
  backup and target model, transfers the archive to `/tmp`, and verifies its
  checksum. It never applies the restore.
- xia-router: `/etc/sysupgrade.conf` explicitly preserves OpenClash profiles,
  custom hooks, provider files, its current core, the diagnostic scripts,
  FRP, Tailscale identity, SSH material, and custom startup files. OpenWrt
  also captures its normal UCI configuration and cron settings.
- The archive includes a package inventory and hardware/firmware metadata.
  It does **not** contain installable package files. PHX separately caches the
  currently installed official OpenClash `0.47.055` `.ipk` under
  `/data/router-backups/xia-router/recovery-tools/`, with a SHA-256 file.
  An upgrade can remove packages even when their configuration survives.

Run an extra backup immediately before a firmware upgrade or major change:

```sh
ssh phx-arm /usr/local/sbin/backup-from-phx.sh
ssh phx-arm /usr/local/sbin/verify-backup.sh /data/router-backups/xia-router/latest
```

The archives contain subscription URLs, Wi-Fi and FRP credentials, Tailscale
identity, and private keys. The PHX directory is root-only (`0700`), and the
Google Drive copy is private to that account; it is not end-to-end encrypted.
Do not commit the archives, package manifest, or monitor token to GitHub.

## Same router, firmware upgrade

1. Run and verify an on-demand PHX backup. In the GL.iNet upgrade UI, choose
   **keep settings**. After boot, check whether packages were removed.
2. Reinstall missing packages for the **new firmware's** package manager and
   architecture. On this `opkg` firmware, the existing generic installer at
   `gl-be3600/install-openclash.sh` in `qy2009/router` selects the official
   OpenClash `.ipk`; never use a newer `apk`/CloudRun 25 asset on `opkg`.
   If GitHub is blocked from China, copy the cached matching `.ipk` from PHX
   and install it with `opkg install /tmp/luci-app-openclash_0.47.055_all.ipk`
   after checking the new firmware still uses `opkg` and compatible dependencies.
   Reinstall any missing `tailscale`, `frpc`, `snmpd`, `ruby`, `ruby-yaml`,
   and `curl` from a compatible firmware feed. Do not blindly replay every
   entry in `packages.txt`; many entries are firmware built-ins.
3. Run `ash /etc/openclash/post-upgrade-check.sh` on the router.
   Check OpenClash, FRP, Tailscale, the Tailscale bypass, hourly diagnostics,
   and the PHX backup path. Restart services only after their packages and
   files are present.
4. If settings were *not* kept, stage the **matching-model** archive with
   `ssh phx-arm /usr/local/sbin/stage-restore-from-phx.sh root@100.111.111.119`
   while Tailscale/SSH is working, or copy it manually via LAN/PC. Then use
   OpenWrt's `sysupgrade -r /tmp/xia-router-sysupgrade.tar.gz` and reboot.
   This restores credentials
   and identities as well as configuration. Do it only on the original unit
   or when the original unit is offline and a same-model replacement is being
   commissioned.

`sysupgrade -r` is deliberately not automated here: package/firmware
compatibility and replacement identity must be checked first. The PHX backup
has been extracted and verified without touching the live router; a full
firmware-upgrade restore has not been exercised.

## Replacement device

Use the same GL-MT2500 model and compatible firmware where possible. Bring up
the new router with its own LAN address first. Keep the old router powered off
before activating FRP or a copied Tailscale identity.

For a **same-model replacement** with the old unit retired, the full restore
method above is available after checking the model and firmware metadata in
`router-info.txt`. Then reinstall missing packages and run the post-upgrade
checks. Review network interfaces and the upstream Wi-Fi/router connection
before reconnecting the production LAN.

For a different model or major firmware generation, extract the archive to a
temporary directory and migrate selected files: OpenClash `config`, `custom`,
`overwrite`, `proxy_provider`, `rule_provider`, diagnostic scripts, and the
FRP TOML after reviewing addresses. Recreate network, firewall, SSH host keys,
and Tailscale registration on the new device. Do **not** extract the whole
archive onto a different model.
