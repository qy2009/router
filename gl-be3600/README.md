# GL.iNet GL-BE3600 backup and OpenClash recovery

These scripts were verified against the `travel-router` GL-BE3600 running
OpenWrt 23.05-SNAPSHOT on Qualcomm IPQ5332 (`aarch64`, `opkg`).

## Back up before a firmware update

```sh
curl -fsSL https://raw.githubusercontent.com/qy2009/router/main/gl-be3600/backup-router.sh \
  -o /tmp/backup-router.sh
chmod 700 /tmp/backup-router.sh
/tmp/backup-router.sh --encrypt
```

Download both the resulting `.tar.gz.enc` file and its `.sha256` file from the
router before upgrading. `/tmp` is erased during reboot or firmware flashing.
Keep the encryption password somewhere safe.

The archive includes `/etc/config`, VPN material, Wi-Fi configuration,
Tailscale state, GoodCloud's `gl-cloud` UCI config, Dropbear keys, cron jobs,
and an installed-package manifest.

For OpenClash, it selectively includes:

- `/etc/config/openclash` through the normal `/etc/config` backup
- `/etc/openclash/config` for YAML profiles
- `/etc/openclash/custom` for custom rules and overrides
- `/etc/openclash/proxy_provider` and `/etc/openclash/rule_provider`

It intentionally excludes the OpenClash application, cores, history, logs,
caches, and downloaded GeoIP/GeoSite databases. Reinstall OpenClash first after
a firmware upgrade, restore the selected configuration, and let the new version
download fresh runtime data.

**Never commit a backup archive to this repository.** It contains Wi-Fi
passwords, VPN private keys, Tailscale identity, and cloud tokens.

## Reinstall OpenClash after a firmware update

For the normal case where the firmware retained all settings, reinstall both
OpenClash and the LuCI Argon theme with:

```sh
curl -fsSL https://raw.githubusercontent.com/qy2009/router/main/gl-be3600/after-firmware-upgrade.sh \
  -o /tmp/after-firmware-upgrade.sh
chmod 700 /tmp/after-firmware-upgrade.sh
/tmp/after-firmware-upgrade.sh
```

This does not restore or overwrite router settings. It runs the OpenClash
installer below, installs the latest official Argon package plus its optional
configuration companion, and refreshes LuCI. Use `--skip-openclash` or
`--skip-argon` if only one package is needed.

### OpenClash installer by itself

```sh
curl -fsSL https://raw.githubusercontent.com/qy2009/router/main/gl-be3600/install-openclash.sh \
  -o /tmp/install-openclash.sh
chmod 700 /tmp/install-openclash.sh
/tmp/install-openclash.sh
```

Automatic mode uses a matching package from
[CloudRunFilesBuilder](https://github.com/wkccd/CloudRunFilesBuilder/releases)
on compatible OpenWrt 24/25 firmware. On the verified OpenWrt 23.05 `opkg`
firmware, it uses OpenClash's official architecture-independent `.ipk` because
the latest CloudRun packages target different firmware generations.

To require CloudRun and fail rather than fall back:

```sh
/tmp/install-openclash.sh --source cloudrun
```

If this older firmware cannot negotiate TLS with GitHub, download the matching
OpenClash package in a desktop browser, upload it to `/tmp` through Nexterm,
then install it without another network download:

```sh
/tmp/install-openclash.sh --file /tmp/your-openclash-package.run
```

The same option accepts an official `.ipk` on `opkg` firmware or `.apk` on
newer `apk` firmware. The script refuses a package-manager mismatch.

After reinstalling, restore only the OpenClash configuration directories from
your backup if the firmware upgrade did not preserve them. Do not blindly
overwrite all of `/etc/config` across major firmware generations.

