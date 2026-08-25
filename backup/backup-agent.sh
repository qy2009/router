#!/bin/bash
# backup-agent.sh — generalized restic backup agent for the Oracle VPS fleet.
#
# The SAME copy of this file goes on every VPS unchanged. Per-host
# differences (hostname label, Kuma monitor URL, retention overrides) live
# in /etc/backup-agent.conf — see backup-agent.conf.example.
#
# v2 changes, per Ray's follow-up:
#   - Dropped the per-database-engine dump logic. Simpler and more robust:
#     stop every container during the backup window, snapshot, restart.
#     Weekly cadence + personal scale makes a few minutes of downtime a
#     fair trade for guaranteed filesystem consistency on *everything*
#     (including SQLite apps, which had no clean dump path before) — and
#     it makes recovery simpler too, since there's no per-DB restore step,
#     just `docker compose up` against already-consistent data.
#     Opt a specific container OUT with: docker run --label backup.keep-running=true ...
#   - System config files (ssmtp, fail2ban, sysctl, sshd_config, this
#     agent's own config) are now backed up at their REAL original paths
#     via a manifest, instead of being copied into /root first. That's
#     what makes automated restore possible — restic preserves absolute
#     paths, so `restic restore --target /` puts each file straight back
#     where it came from with no manual "which file goes where" step.
#   - Retention re-tuned for weekly (not daily) runs.
#   - Secrets moved out of /etc/backup-agent's backed-up files entirely —
#     see secrets.env handling below.
#
# Usage: normally invoked by cron (see install-backup-agent.sh). Can be
# run by hand for testing: /usr/local/bin/backup-agent.sh

set -uo pipefail
# Not -e: several steps here are intentionally best-effort. The two steps
# that matter (restic backup, restic forget) check their own exit codes.

LOCKFILE="/var/run/backup-agent.lock"
exec 9>"$LOCKFILE"
flock -n 9 || { echo "Backup already running — exiting."; exit 1; }

# ---- defaults, overridable in /etc/backup-agent.conf ----
HOST_LABEL="$(hostname)"
DATA_DIR="/data"
ROOT_DIR="/root"
LOGFILE="/var/log/backup-agent.log"
EXCLUDE_FILE="/etc/backup-agent/excludes.txt"
SYSTEM_FILES_MANIFEST="/etc/backup-agent/system-files.txt"
COVERAGE_IGNORE_FILE="/etc/backup-agent/coverage-ignore.txt"
CRONTAB_DUMP="/etc/backup-agent/crontab_root.dump"
SECRETS_FILE="/etc/backup-agent/secrets.env"
GDRIVE_REMOTE="gdrive"
GDRIVE_PATH=""   # defaults to Backup_CloudVPS/<hostname>; override in conf if needed
UPLOAD_LOG=true  # copy the log to Drive after each run -> Backup_CloudVPS/_logs/<host>.log
                 # (viewable from Drive web UI or any /gdrive mount, no extra infra)
# Weekly cadence: 8 weekly snapshots (~2 months of week-by-week rollback),
# tapering to monthly for 6 months, yearly for 2 years beyond that. Restic
# dedups unchanged blocks, so this costs far less space than 8+6+2
# snapshots implies — it's not 16 full copies.
RETENTION="--keep-weekly 8 --keep-monthly 6 --keep-yearly 2"
KUMA_PUSH_URL=""
KUMA_PUSH_RETRIES=9          # retries cover slow local Kuma restarts after containers resume
KUMA_PUSH_RETRY_DELAY=10     # seconds between heartbeat attempts
PUSHOVER_NOTIFY_SUCCESS=true   # set false in conf if daily-success pings get noisy
EMAIL_RECIPIENT=""             # e.g. qy2009@gmail.com — failure emails via ssmtp, with log tail

CONF="/etc/backup-agent.conf"
[ -f "$CONF" ] && source "$CONF"

if [ -z "$GDRIVE_PATH" ]; then
    GDRIVE_PATH="Backup_CloudVPS/${HOST_LABEL}"
fi
export RESTIC_REPOSITORY="rclone:${GDRIVE_REMOTE}:${GDRIVE_PATH}"

# ---- secrets ----
# Deliberately NOT included in the backup (see system-files.txt) — a
# secrets file that's only ever backed up into the repo it unlocks defeats
# the point. Keep an out-of-band copy (password manager); see RECOVERY.md.
if [ -f "$SECRETS_FILE" ]; then
    source "$SECRETS_FILE"
else
    echo "Missing $SECRETS_FILE — aborting." >&2
    exit 1
fi

exec >>"$LOGFILE" 2>&1
echo "===== [$HOST_LABEL] Backup run started: $(date) ====="

send_alert() {
    local STATUS=$1 MSG=$2
    [ -n "${PUSHOVER_TOKEN:-}" ] && curl -s --form-string "token=$PUSHOVER_TOKEN" --form-string "user=$PUSHOVER_USER" \
        --form-string "title=${HOST_LABEL} Backup $STATUS" --form-string "message=$MSG" \
        https://api.pushover.net/1/messages.json >/dev/null
}

push_kuma_heartbeat() {
    local STATUS=$1 MSG=$2 attempt
    local RETRIES=${KUMA_PUSH_RETRIES:-9}
    local RETRY_DELAY=${KUMA_PUSH_RETRY_DELAY:-10}

    [ -z "$KUMA_PUSH_URL" ] && return 0

    for ((attempt = 1; attempt <= RETRIES; attempt++)); do
        if curl -fsS -m 10 -G "$KUMA_PUSH_URL" \
            --data-urlencode "status=$STATUS" --data-urlencode "msg=$MSG" \
            >/dev/null 2>&1; then
            echo "Kuma heartbeat delivered on attempt $attempt."
            return 0
        fi

        if [ "$attempt" -lt "$RETRIES" ]; then
            echo "Kuma heartbeat attempt $attempt/$RETRIES failed; retrying in ${RETRY_DELAY}s."
            sleep "$RETRY_DELAY"
        fi
    done

    echo "WARNING: Kuma heartbeat delivery failed after $RETRIES attempts."
    return 1
}

send_failure_email() {
    # Full context by email: Pushover messages cap at 1024 chars, so the
    # push says "it broke", the email says why (last 50 log lines).
    [ -z "$EMAIL_RECIPIENT" ] && return 0
    command -v ssmtp >/dev/null 2>&1 || return 0
    {
        echo "Subject: [${HOST_LABEL}] Backup FAILED $(date +%F)"
        echo ""
        echo "Backup failed on ${HOST_LABEL}. Last 50 log lines from ${LOGFILE}:"
        echo "----------------------------------------------------------------"
        tail -n 50 "$LOGFILE"
    } | ssmtp "$EMAIL_RECIPIENT"
}

mkdir -p "$(dirname "$EXCLUDE_FILE")"
[ -f "$EXCLUDE_FILE" ] || { echo "WARNING: $EXCLUDE_FILE missing — creating empty one."; touch "$EXCLUDE_FILE"; }
# restic errors out (not skips) if --exclude-file doesn't exist.

# ---- snapshot crontab + config to their real paths (see manifest below) ----
crontab -l > "$CRONTAB_DUMP" 2>/dev/null || echo "# no crontab" > "$CRONTAB_DUMP"

# ---- docker-compose export for every container (running or not) ----
CONFIG_ERRORS=0
containers=$(docker ps -a --format "{{.Names}}")
for container in $containers; do
    MATCHING_DIR=$(find "$DATA_DIR" -maxdepth 1 -type d -name "*$container*" | head -n 1)
    TARGET_DIR=${MATCHING_DIR:-"$DATA_DIR/$container"}
    mkdir -p "$TARGET_DIR"
    OUT=$(docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
        ghcr.io/red5d/docker-autocompose "$container" 2>/dev/null | \
        sed '/hostname:/d; /domainname:/d; /container_config:/d; /image_id:/d; /networks:/,$d; /^version:/d')
    if [ -n "$OUT" ]; then
        printf '%s\n\nnetworks:\n  default:\n    name: bridge\n' "$OUT" > "$TARGET_DIR/docker-compose.yml"
    else
        echo "WARNING: docker-autocompose returned nothing for $container"
        CONFIG_ERRORS=$((CONFIG_ERRORS + 1))
    fi
done

# ---- coverage audit: is every container's data actually inside the backup? ----
# The backup covers $DATA_DIR + $ROOT_DIR + the system-files manifest. A
# container using a NAMED DOCKER VOLUME (data in /var/lib/docker/volumes)
# or a bind mount outside those paths would be silently NOT backed up —
# the compose file would come back on restore, but its data wouldn't.
# This audit makes that failure loud instead of silent.
path_is_covered() {
    local src=$1 configured
    # Stopped legacy containers can retain bind-mount definitions whose host
    # paths were already removed. There is no data at those paths to protect.
    [ -e "$src" ] || return 0
    case "$src" in
        "$DATA_DIR"|"$DATA_DIR"/*|"$ROOT_DIR"|"$ROOT_DIR"/*) return 0 ;;
        /|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/run/*|/var/run|/var/run/*|/var/lib/docker|/var/lib/docker/volumes) return 0 ;;
        /etc/localtime|/etc/timezone|/lib/modules) return 0 ;;
    esac

    for list in "$SYSTEM_FILES_MANIFEST" "$COVERAGE_IGNORE_FILE"; do
        [ -f "$list" ] || continue
        while IFS= read -r configured; do
            [ -z "$configured" ] && continue
            case "$configured" in \#*) continue ;; esac
            case "$src" in
                "$configured"|"$configured"/*) return 0 ;;
            esac
        done < "$list"
    done
    return 1
}

UNCOVERED=""
for container in $containers; do
    while IFS= read -r src; do
        [ -z "$src" ] && continue
        path_is_covered "$src" || UNCOVERED="$UNCOVERED\n  $container -> $src"
    done < <(docker inspect --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' "$container" 2>/dev/null)
done
if [ -n "$UNCOVERED" ]; then
    echo -e "WARNING: container data OUTSIDE the backup scope:$UNCOVERED"
    echo "  Fix: recreate those containers with bind mounts under $DATA_DIR,"
    echo "  add data paths to $SYSTEM_FILES_MANIFEST, or intentionally ignored"
    echo "  non-data/cache/remote paths to $COVERAGE_IGNORE_FILE."
fi

# ---- stop every running container for a consistent snapshot ----
RUNNING_CONTAINERS=$(docker ps --format "{{.Names}}")
STOPPED=""
for container in $RUNNING_CONTAINERS; do
    KEEP_RUNNING=$(docker inspect --format '{{ index .Config.Labels "backup.keep-running"}}' "$container" 2>/dev/null)
    if [ "$KEEP_RUNNING" = "true" ]; then
        echo "  leaving $container running (backup.keep-running=true)"
        continue
    fi
    echo "  stopping $container"
    docker stop "$container" >/dev/null
    STOPPED="$STOPPED $container"
done

# ---- build the backup target list: $DATA_DIR, $ROOT_DIR, + manifested system files that exist ----
BACKUP_TARGETS=("$DATA_DIR" "$ROOT_DIR")
if [ -f "$SYSTEM_FILES_MANIFEST" ]; then
    while IFS= read -r path; do
        [ -z "$path" ] && continue
        case "$path" in \#*) continue ;; esac
        if [ -e "$path" ]; then
            BACKUP_TARGETS+=("$path")
        else
            echo "  NOTE: $path in manifest but not found on disk, skipping"
        fi
    done < "$SYSTEM_FILES_MANIFEST"
fi

# ---- backup ----
echo "Uploading to ${RESTIC_REPOSITORY}..."
# --pack-size 64: Google Drive rate-limits many-small-object uploads hard;
# larger pack files mean far fewer remote writes per backup.
if restic backup "${BACKUP_TARGETS[@]}" --exclude-file="$EXCLUDE_FILE" --pack-size 64; then
    BACKUP_OK=1
else
    BACKUP_OK=0
fi

for c in $STOPPED; do
    echo "  restarting $c"
    docker start "$c" >/dev/null
done

FORGET_OK=1
if [ "$BACKUP_OK" -eq 1 ]; then
    # Weekly cadence already makes prune infrequent enough to run every
    # time — no need to split forget/prune like a daily job would.
    # shellcheck disable=SC2086
    restic forget $RETENTION --prune || FORGET_OK=0
fi

# ---- publish log to Drive (best-effort; viewable anywhere) ----
if [ "$UPLOAD_LOG" = "true" ]; then
    rclone copyto "$LOGFILE" "${GDRIVE_REMOTE}:Backup_CloudVPS/_logs/${HOST_LABEL}.log" 2>/dev/null || true
fi

# ---- report ----
if [ "$BACKUP_OK" -eq 1 ] && [ "$FORGET_OK" -eq 1 ]; then
    echo "Backup finished at $(date)."
    SUMMARY="Backup OK at $(date '+%F %H:%M')."
    [ "$CONFIG_ERRORS" -gt 0 ] && SUMMARY="$SUMMARY $CONFIG_ERRORS compose export(s) failed."
    [ -n "$UNCOVERED" ] && SUMMARY="$SUMMARY WARNING: some container data outside backup scope — see log."
    [ "$PUSHOVER_NOTIFY_SUCCESS" = "true" ] && send_alert "SUCCESS" "$SUMMARY"
    push_kuma_heartbeat "up" "OK" || true
    exit 0
else
    LOG_TAIL=$(tail -n 5 "$LOGFILE" 2>/dev/null | cut -c1-800)
    send_alert "FAILED" "Backup failed on ${HOST_LABEL}. Full log: ${LOGFILE}. Last lines: ${LOG_TAIL}"
    send_failure_email
    push_kuma_heartbeat "down" "backup or forget failed" || true
    exit 1
fi

