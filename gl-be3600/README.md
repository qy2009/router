# GL.iNet GL-BE3600 backup and OpenClash recovery

These scripts were tailored against a GL-BE3600 running OpenWrt
21.02-SNAPSHOT on `mediatek/mt7981` (`aarch64_cortex-a53`, `opkg`).

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
Tailscale state, GoodCloud's `gl-cloud` UCI config, OpenClash configuration,
Dropbear keys, cron jobs, and an installed-package manifest.

**Never commit a backup archive to this repository.** It contains Wi-Fi
passwords, VPN private keys, Tailscale identity, and cloud tokens.

## Reinstall OpenClash after a firmware update

```sh
curl -fsSL https://raw.githubusercontent.com/qy2009/router/main/gl-be3600/install-openclash.sh \
  -o /tmp/install-openclash.sh
chmod 700 /tmp/install-openclash.sh
/tmp/install-openclash.sh
```

Automatic mode uses a matching package from
[CloudRunFilesBuilder](https://github.com/wkccd/CloudRunFilesBuilder/releases)
on compatible OpenWrt 24/25 firmware. On the current OpenWrt 21.02 `opkg`
firmware, it uses OpenClash's official architecture-independent `.ipk` because
the latest `25-...` CloudRun package targets newer `apk` firmware.

To require CloudRun and fail rather than fall back:

```sh
/tmp/install-openclash.sh --source cloudrun
```

After reinstalling, restore only the OpenClash configuration directories from
your backup if the firmware upgrade did not preserve them. Do not blindly
overwrite all of `/etc/config` across major firmware generations.


