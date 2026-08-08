#!/bin/bash
# cloudflare-backup.sh — leg 5 from Backup-Architecture.md.
# Exports zone/DNS/WAF config via cf-terraforming, and (if you use R2)
# mirrors bucket data R2 -> Oracle Object Storage -> Google Drive.
#
# Runs centrally (Unraid). Requires: cf-terraforming, rclone (with r2-remote
# and oci-remote configured — oci-remote can use rclone's native Oracle
# Object Storage backend, no separate S3 keys needed).

set -uo pipefail

STAGE="/mnt/user/backup-staging/cloudflare"
GDRIVE_REMOTE="gdrive-personal:Backups/Cloudflare"
GDRIVE_VERSIONS="gdrive-personal:Backups-versions/Cloudflare"
LOGFILE="/mnt/user/backup-logs/cloudflare-backup.log"
KUMA_PUSH_URL=""   # from Uptime Kuma, monitor: cloudflare-backup

export CLOUDFLARE_API_TOKEN="CHANGE_ME"   # scoped read-only token — not your global API key
ZONE_ID="CHANGE_ME"

R2_BUCKET_ENABLED=false   # flip to true if you use R2
R2_REMOTE="r2-remote:your-bucket"
OCI_REMOTE="oci-remote:your-bucket"

exec >>"$LOGFILE" 2>&1
echo "===== Cloudflare backup started: $(date) ====="
mkdir -p "$STAGE/config"

FAILED=0

# --- 1. Config snapshot: DNS records, versioned as Terraform files ---
cf-terraforming generate --resource-type "cloudflare_record" --zone "$ZONE_ID" \
    > "$STAGE/config/dns-$(date +%F).tf" || FAILED=1

rclone sync "$STAGE/config" "${GDRIVE_REMOTE}/config" \
    --backup-dir "${GDRIVE_VERSIONS}/config/$(date +%F)" \
    --log-file "$LOGFILE" --log-level INFO || FAILED=1

# --- 2. R2 bucket data, if applicable: two hops, R2 never touches Drive directly ---
if [ "$R2_BUCKET_ENABLED" = true ]; then
    rclone sync "$R2_REMOTE" "$OCI_REMOTE" \
        --backup-dir "${OCI_REMOTE}-versions/$(date +%F)" \
        --log-file "$LOGFILE" --log-level INFO || FAILED=1

    rclone sync "$OCI_REMOTE" "${GDRIVE_REMOTE}/r2-data" \
        --backup-dir "${GDRIVE_VERSIONS}/r2-data/$(date +%F)" \
        --log-file "$LOGFILE" --log-level INFO || FAILED=1
    # Oracle Always Free Object Storage caps at 20GB combined — watch this
    # if R2 data grows; excess gets deleted if the free trial has lapsed.
fi

if [ "$FAILED" -eq 0 ]; then
    echo "Done: $(date)"
    [ -n "$KUMA_PUSH_URL" ] && curl -fsS -m 10 -G "$KUMA_PUSH_URL" --data-urlencode "status=up" --data-urlencode "msg=OK" >/dev/null
    exit 0
else
    echo "One or more steps failed — see log above."
    [ -n "$KUMA_PUSH_URL" ] && curl -fsS -m 10 -G "$KUMA_PUSH_URL" --data-urlencode "status=down" --data-urlencode "msg=see log" >/dev/null
    exit 1
fi
