# GL.iNet GL-X3000 Home Router backup and firmware recovery

These scripts target the `home-router` GL.iNet GL-X3000. They were verified on
OpenWrt 21.02-SNAPSHOT, `aarch64_cortex-a53`, using `opkg`.

## Files

- `router-backup.sh` — weekly configuration backup to the attached SD card
- `install-backup.sh` — installs the backup script, cron schedule, retention
  rules, and a notification configuration example
- `after-firmware-upgrade.sh` — reinstalls packages commonly removed by a
  firmware upgrade without overwriting retained UCI settings

## Install or update the weekly backup

```sh
curl -fsSL https://raw.githubusercontent.com/qy2009/router/main/gl-x3000/install-backup.sh \
  -o /tmp/install-backup.sh
chmod 700 /tmp/install-backup.sh
/tmp/install-backup.sh
```

The default schedule is Sunday at 02:00:

```cron
0 2 * * 0 /usr/local/bin/router-backup.sh
```

Use another schedule by passing one quoted cron expression:

```sh
/tmp/install-backup.sh --schedule "30 3 * * 0"
```

The installer is idempotent. It preserves existing cron entries and
`/etc/router-backup-notify.env`, keeps a timestamped rollback copy when the
installed script changes, enables/restarts cron, and adds these files to
`/etc/sysupgrade.conf`:

- `/usr/local/bin/router-backup.sh`
- `/etc/router-backup-notify.env`

The last item is important because the GL-X3000 did not otherwise retain the
private notification file during sysupgrade.

### Pushover and Uptime Kuma

Copy the generated example and insert private values locally on the router:

```sh
cp /etc/router-backup-notify.env.example /etc/router-backup-notify.env
chmod 600 /etc/router-backup-notify.env
vi /etc/router-backup-notify.env
```

Do not commit that file. When Cloudflare Access protects the public Kuma URL,
use Kuma's private Tailscale address for `UPTIME_PUSH_URL`.

## What is backed up

Each successful run creates three files plus SHA-256 sidecars under the
attached SD card's `router-backups/` directory:

1. An OpenWrt `sysupgrade` configuration archive. This includes retained
   network, Wi-Fi, firewall, DHCP reservations, VPN, GL.iNet, and other UCI
   settings.
2. A selective OpenClash configuration archive containing profiles, custom
   rules, overrides, proxy providers, and rule providers. It excludes the app,
   core binary, history, logs, caches, and downloaded GeoIP/GeoSite databases.
3. An installed-package inventory.

The script detects the actual mount point for `/dev/sda1`, writes files
atomically, rejects empty output, prevents overlapping jobs with `flock`, keeps
persistent logs, verifies Uptime Kuma's JSON response, and retains eight weekly
sets. A failure sends a down heartbeat and Pushover alert.

Run a backup manually and inspect its result with:

```sh
/usr/local/bin/router-backup.sh
echo $?
tail -n 30 /mnt/sda1/router-backups/backup-history.log
```

## After a firmware upgrade

The firmware is already OpenWrt. The command below treats the commonly intended
"install OpenWrt" request as **reinstall OpenClash**, then also installs Argon,
Lucky, p910nd, the FRP client, SNMPD, and the backup cron job:

```sh
curl -fsSL https://raw.githubusercontent.com/qy2009/router/main/gl-x3000/after-firmware-upgrade.sh \
  -o /tmp/after-firmware-upgrade.sh
chmod 700 /tmp/after-firmware-upgrade.sh
/tmp/after-firmware-upgrade.sh
```

The service packages are:

- `lucky` and `luci-app-lucky`
- `p910nd` and `luci-app-p910nd`
- `frpc` and `luci-app-frpc`
- `snmpd` and `luci-app-snmpd`

OpenClash and Argon reuse the guarded installers in `gl-be3600/`, including
package-manager and architecture checks. Existing `/etc/config` settings are
not restored or overwritten; installed services reuse settings retained by the
firmware. OpenClash is started only when its retained UCI enable setting is `1`.

Preview the detected router and planned actions without changing anything:

```sh
/tmp/after-firmware-upgrade.sh --check-only
```

Optional switches:

```text
--openclash-source auto|cloudrun|official
--skip-openclash
--skip-argon
--skip-backup
--skip-services
```

Never commit router backup archives or notification credentials to this public
repository. The archives contain Wi-Fi passwords, VPN keys, device assignments,
and other private configuration.
