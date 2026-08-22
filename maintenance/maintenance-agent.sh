#!/usr/bin/env bash
# Monthly, backup-gated maintenance for Ray's VPS fleet.
# Configure in /etc/maintenance-agent.conf; install with
# install-maintenance-agent.sh.

set -uo pipefail

LOCKFILE="/var/run/maintenance-agent.lock"
exec 9>"$LOCKFILE"
flock -n 9 || { echo "Maintenance already running -- exiting."; exit 1; }

HOST_LABEL="$(hostname)"
LOGFILE="/var/log/maintenance-agent.log"
BACKUP_COMMAND="/usr/local/bin/backup-agent.sh"
SECRETS_FILE="/etc/backup-agent/secrets.env"
MAINTENANCE_KUMA_PUSH_URL=""
PUSHOVER_NOTIFY_SUCCESS=true

UPDATE_SYSTEM=true
UPDATE_OPENLITESPEED="auto" # auto, true, or false
UPDATE_DOCKER_COMPOSE=true
AUTO_REBOOT=true
REBOOT_DELAY_MINUTES=2
HEALTH_TIMEOUT_SECONDS=180
HTTP_CHECK_TIMEOUT_SECONDS=20

# Deliberately explicit. Each entry must be a directory containing a real,
# operator-maintained compose.yaml/docker-compose.yml -- not an autocompose
# recovery export produced by backup-agent.sh.
COMPOSE_PROJECT_DIRS=()

# Optional URLs that must return HTTP 2xx/3xx after package/container updates.
HEALTHCHECK_URLS=()

CONF="/etc/maintenance-agent.conf"
[ -f "$CONF" ] && source "$CONF"

mkdir -p "$(dirname "$LOGFILE")"
exec >>"$LOGFILE" 2>&1
echo "===== [$HOST_LABEL] Maintenance started: $(date -Is) ====="

send_alert() {
    local status=$1 message=$2
    if [ -f "$SECRETS_FILE" ]; then
        # shellcheck disable=SC1090
        source "$SECRETS_FILE"
    fi
    [ -n "${PUSHOVER_TOKEN:-}" ] || return 0
    curl -fsS -m 15 \
        --form-string "token=$PUSHOVER_TOKEN" \
        --form-string "user=${PUSHOVER_USER:-}" \
        --form-string "title=${HOST_LABEL} Maintenance ${status}" \
        --form-string "message=$message" \
        https://api.pushover.net/1/messages.json >/dev/null || true
}

push_kuma() {
    local status=$1 message=$2
    [ -n "$MAINTENANCE_KUMA_PUSH_URL" ] || return 0
    curl -fsS -m 15 -G "$MAINTENANCE_KUMA_PUSH_URL" \
        --data-urlencode "status=$status" \
        --data-urlencode "msg=$message" >/dev/null || true
}

fail() {
    local message=$1
    echo "ERROR: $message"
    send_alert "FAILED" "$message. See $LOGFILE"
    push_kuma down "$message"
    exit 1
}

require_root() {
    [ "$(id -u)" -eq 0 ] || fail "maintenance-agent must run as root"
}

run_backup() {
    [ -x "$BACKUP_COMMAND" ] || fail "backup command is missing or not executable: $BACKUP_COMMAND"
    echo "[1/6] Running mandatory pre-maintenance backup..."
    "$BACKUP_COMMAND" || fail "pre-maintenance backup failed; no updates were attempted"
}

record_running_containers() {
    RUNNING_BEFORE=()
    command -v docker >/dev/null 2>&1 || return 0
    mapfile -t RUNNING_BEFORE < <(docker ps --format '{{.Names}}')
}

update_system() {
    [ "$UPDATE_SYSTEM" = true ] || { echo "[2/6] System package updates disabled."; return; }
    echo "[2/6] Updating packages within the current OS release..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update || fail "package-index refresh failed"
    apt-get -y upgrade || fail "system package upgrade failed"
}

update_openlitespeed() {
    local enabled=$UPDATE_OPENLITESPEED
    if [ "$enabled" = auto ]; then
        dpkg-query -W -f='${Status}' openlitespeed 2>/dev/null | grep -q 'install ok installed' && enabled=true || enabled=false
    fi
    [ "$enabled" = true ] || { echo "[3/6] OpenLiteSpeed not installed or update disabled."; return; }

    echo "[3/6] Verifying OpenLiteSpeed package and service..."
    # apt-get upgrade above already upgrades third-party packages whose APT
    # origin is configured. This explicit command makes intent and logs clear.
    apt-get -y install --only-upgrade openlitespeed || fail "OpenLiteSpeed upgrade failed"
    if command -v openlitespeed >/dev/null 2>&1; then
        openlitespeed -t || fail "OpenLiteSpeed configuration validation failed"
    elif [ -x /usr/local/lsws/bin/openlitespeed ]; then
        /usr/local/lsws/bin/openlitespeed -t || fail "OpenLiteSpeed configuration validation failed"
    fi
    systemctl is-active --quiet lsws || fail "OpenLiteSpeed service is not active"
}

find_compose_file() {
    local dir=$1 name
    for name in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
        [ -f "$dir/$name" ] && { printf '%s\n' "$dir/$name"; return 0; }
    done
    return 1
}

update_compose_projects() {
    local dir compose_file
    [ "$UPDATE_DOCKER_COMPOSE" = true ] || { echo "[4/6] Docker Compose updates disabled."; return; }
    command -v docker >/dev/null 2>&1 || { echo "[4/6] Docker not installed."; return; }
    docker compose version >/dev/null 2>&1 || fail "Docker Compose plugin is unavailable"

    echo "[4/6] Updating explicitly allowed Compose projects..."
    if [ "${#COMPOSE_PROJECT_DIRS[@]}" -eq 0 ]; then
        echo "  No COMPOSE_PROJECT_DIRS configured; container images were not changed."
    fi
    for dir in "${COMPOSE_PROJECT_DIRS[@]}"; do
        [ -d "$dir" ] || fail "Compose project directory does not exist: $dir"
        compose_file=$(find_compose_file "$dir") || fail "No Compose file found in $dir"
        echo "  Updating $dir ($compose_file)"
        docker compose -f "$compose_file" config --quiet || fail "Compose validation failed: $dir"
        docker compose -f "$compose_file" pull || fail "Image pull failed: $dir"
        docker compose -f "$compose_file" up -d || fail "Compose deployment failed: $dir"
    done

    mapfile -t STANDALONE_CONTAINERS < <(
        docker ps --format '{{.Names}} {{.Label "com.docker.compose.project"}}' |
        awk '$2 == "" {print $1}'
    )
    if [ "${#STANDALONE_CONTAINERS[@]}" -gt 0 ]; then
        echo "  NOTE: standalone docker-run containers were intentionally not recreated:"
        printf '    %s\n' "${STANDALONE_CONTAINERS[@]}"
        echo "  Migrate them to maintained Compose files before adding their directories to the allowlist."
    fi
}

wait_for_containers() {
    local deadline now name state health
    [ "${#RUNNING_BEFORE[@]}" -gt 0 ] || return 0
    deadline=$(( $(date +%s) + HEALTH_TIMEOUT_SECONDS ))
    while :; do
        local pending=0
        for name in "${RUNNING_BEFORE[@]}"; do
            state=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)
            health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null || true)
            if [ "$state" != running ] || { [ "$health" != none ] && [ "$health" != healthy ]; }; then
                pending=1
                echo "  waiting: $name state=${state:-missing} health=${health:-unknown}"
            fi
        done
        [ "$pending" -eq 0 ] && return 0
        now=$(date +%s)
        [ "$now" -ge "$deadline" ] && return 1
        sleep 10
    done
}

run_health_checks() {
    local url
    echo "[5/6] Running post-update health checks..."
    wait_for_containers || fail "one or more previously running containers failed their health check"
    for url in "${HEALTHCHECK_URLS[@]}"; do
        curl -fsSL --max-time "$HTTP_CHECK_TIMEOUT_SECONDS" "$url" >/dev/null || fail "HTTP health check failed: $url"
    done
    if command -v docker >/dev/null 2>&1; then
        systemctl is-active --quiet docker || fail "Docker service is not active"
    fi
}

finish_and_reboot_if_needed() {
    local reboot_message=""
    if [ -f /var/run/reboot-required ]; then
        reboot_message=" Reboot required."
        if [ "$AUTO_REBOOT" = true ]; then
            reboot_message=" Reboot scheduled in ${REBOOT_DELAY_MINUTES} minute(s)."
        fi
    fi

    echo "[6/6] Maintenance completed successfully.${reboot_message}"
    [ "$PUSHOVER_NOTIFY_SUCCESS" = true ] && send_alert "SUCCESS" "Updates and health checks passed.${reboot_message}"
    push_kuma up "Updates and health checks passed.${reboot_message}"

    if [ -f /var/run/reboot-required ] && [ "$AUTO_REBOOT" = true ]; then
        shutdown -r "+${REBOOT_DELAY_MINUTES}" "Scheduled reboot after successful monthly maintenance"
    fi
}

require_root
record_running_containers
run_backup
update_system
update_openlitespeed
update_compose_projects
run_health_checks
finish_and_reboot_if_needed

