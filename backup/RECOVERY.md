# Recovery Runbook

A backup you haven't restored from is a theory, not a backup. This is the "recover" half of Backup-Architecture.md — walk through each of these at least once, before you need them for real.

## 0. Bootstrapping access from nothing

For the VPS fleet, this is solved: `make-secrets-bundle.sh` bundles `rclone.conf` + `secrets.env` + `ssmtp.conf` into one age-passphrase-encrypted file (`secrets-bundle.tar.age`), safe to commit alongside the scripts in the (public) GitHub repo. `install-backup-agent.sh` and `restore-agent.sh` both auto-decrypt it if it's present. That means the entire VPS bootstrap — new box or disaster recovery — is:

```bash
git clone https://github.com/qy2009/router.git && cd router/backup
bash install-backup-agent.sh      # or restore-agent.sh <host-label>
# -> prompts once for the age passphrase, unlocks all three files
```

**The one thing that can't be automated away:** that passphrase itself. It's the single point of failure for the whole fleet by design — keep it in a password manager, not written down next to a VPS. If you ever suspect it's leaked, re-run `make-secrets-bundle.sh` with a new passphrase and re-commit.

This covers the VPS legs. A few things still need their own out-of-band copy, since they're outside the bundle's scope:
- Every Duplicati backup job's passphrase (if you're still running any).
- The Cloudflare API token and Oracle Object Storage credentials used by `cloudflare-backup.sh` on Unraid.
- Duplicati/MailStore-side secrets, which live on Windows/Unraid, not the VPS fleet.

## 1. Restoring a VPS (restic / backup-agent.sh)

**Automated path:**
1. Spin up a new Oracle VPS, run your existing `vps-setup.sh`.
2. Copy the out-of-band `rclone.conf` to `/root/.config/rclone/rclone.conf`, plus `restore-agent.sh` and `backup-agent.sh`.
3. `bash restore-agent.sh <host-label>` — same `HOST_LABEL` the dead VPS used. It restores everything (data, docker-compose files, crontab, ssmtp/fail2ban/sysctl config) to their original paths, reinstalls the crontab, and brings every `docker compose` service back up. Since backups now stop all containers before snapshotting (see the note in `backup-agent.sh`), there's no per-database restore step needed — the data was already consistent when it was captured.
4. It'll prompt for `RESTIC_PASSWORD` — pull that from your password manager, it's intentionally not stored anywhere in the backup itself.
5. It deliberately does **not** auto-restart `sshd` even though `sshd_config` gets restored — review it first (`sshd -t`), then restart it yourself, so a bad config can't lock you out from inside the very session you're using to fix it.
6. Verify, then re-point DNS/whatever else pointed at the old VPS's IP.

**What's happening under the hood**, if you ever need to do it by hand:
```bash
source /etc/backup-agent/secrets.env
export RESTIC_REPOSITORY="rclone:gdrive:Backup_CloudVPS/<host-label>"
restic snapshots                      # confirm you're looking at the right repo
restic restore latest --target /      # or --target /tmp/restore to inspect first
crontab /etc/backup-agent/crontab_root.dump
cd /data/<service> && docker compose up -d   # per service
```

## 1b. Restoring a WordPress VPS (restic / backup-agent-wordpress.sh)

Same restic mechanics as above, different target layout since there's no `docker compose` to bring back up — this is a native OpenLiteSpeed + MariaDB install.

```bash
source /etc/backup-agent/secrets.env
export RESTIC_REPOSITORY="rclone:oracle:vps-backups/Backup_CloudVPS/<host-label>"
restic snapshots
restic restore latest --target /                 # puts /var/www and the lsws vhost confs back in place
mysql -u root < /var/backups/mysql-dumps/all-databases.sql   # restores every DB from the dump restic just restored
chown -R www-data:www-data /var/www/<site>        # restic preserves ownership, but double check after a
                                                    # cross-host restore (uid/gid can differ on a fresh box)
systemctl restart lsws mariadb
```

If MariaDB root has a real password by the time you're restoring, source it from `MYSQL_PASSWORD` in the restored `secrets.env` and pass `-p"$MYSQL_PASSWORD"` to the `mysql` import above. Verify the site loads and the DB looks current (check a recent post/order/whatever's easy to eyeball) before repointing DNS.

## 2. Restoring a VPS (Duplicati)

1. Same VPS provisioning as above.
2. Install Duplicati, point it at the Google Drive folder for that VPS.
3. Duplicati's own restore UI lets you browse-and-restore individual files or the whole set — use "Direct restore from backup files" if you don't want to recreate the original scheduled job first.
4. You'll need that VPS's Duplicati passphrase from your out-of-band store.

## 3. Restoring Google Drive itself

If a Google EDU account is suspended or wiped (see the risk section in the main doc — this is the scenario that mitigation is for): pull from whichever propagation copy is most current, OneDrive or Unraid. Since both are full mirrors of the Drive root (assuming the folder-scope setup in the main doc), either can reconstruct the whole tree. `rclone sync` from whichever copy is freshest back into a new Drive account (or skip Drive entirely and re-point VPS backup targets at OneDrive/Unraid directly going forward).

## 4. Restoring GitHub

`git clone --mirror` output in `Backups/GitHub/<repo>.git` on Drive/Unraid is a bare mirror — push it straight back to a new GitHub repo:
```bash
git clone --mirror /path/to/repo.git
cd repo.git
git remote set-url origin https://github.com/you/repo.git
git push --mirror
```
If you also ran the optional `github-backup` metadata export, issues/PRs/wikis are separate JSON/markdown exports, not directly re-importable via `git push` — restoring those means re-creating them via the GitHub API or just keeping them as reference material rather than a one-command restore.

## 5. Restoring Cloudflare

- **DNS/zone config:** the `cf-terraforming`-generated `.tf` files are a point-in-time snapshot, not live infrastructure-as-code by default — apply them with `terraform apply` against a fresh zone, or use them as a reference to manually recreate records via the dashboard/API if you'd rather not stand up Terraform state management for a one-time recovery.
- **R2 data:** `rclone sync` from the Google Drive copy (or the Oracle Object Storage copy, whichever is freshest) back to a new R2 bucket.

## 6. Restoring Gmail (MailStore Home)

MailStore Home's archive store is just a folder — reinstall MailStore Home on any Windows machine, point it at the restored archive folder (from OneDrive/Unraid/USB), and it's immediately searchable again. No special import step.

## 7. Restoring from the external USB

Since it's `rsync --link-dest` snapshots, each dated folder under `/mnt/usb/backup-YYYY-MM-DD/` is a complete, browsable point-in-time copy — no reconstruction needed, just `cp -a` or `rsync` the snapshot you want back to wherever it needs to live.

## Maintenance tie-in

Do at least one of the above for real, on a schedule (quarterly is reasonable), rotating through which leg you test. The goal isn't to prove the backup exists — Kuma already tells you that — it's to prove you (and this runbook) can actually turn it back into a working system under time pressure.
