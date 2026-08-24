#!/usr/bin/env bash
# Capture only operator-supplied environment overrides from the live
# zrh-arm containers. Values are written to root-only files and never printed.

set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }
command -v docker >/dev/null || { echo "docker is required." >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required." >&2; exit 1; }

ENV_DIR=/etc/zrh-arm-compose
install -d -m 700 "$ENV_DIR"
umask 077

capture_env() {
    local container=$1 filename=$2
    shift 2
    local tmp key

    docker inspect "$container" >/dev/null
    tmp=$(mktemp "$ENV_DIR/.${filename}.XXXXXX")
    docker inspect "$container" |
        jq -r --args '
            .[0].Config.Env as $env
            | $ARGS.positional[] as $key
            | ($env[] | select(startswith($key + "=")))
        ' "$@" >"$tmp"

    for key in "$@"; do
        grep -q "^${key}=" "$tmp" || {
            echo "Missing expected variable ${key} on ${container}; refusing partial capture." >&2
            rm -f "$tmp"
            exit 1
        }
    done

    install -m 600 "$tmp" "$ENV_DIR/$filename"
    rm -f "$tmp"
    echo "Captured $container -> $ENV_DIR/$filename ($(wc -l <"$ENV_DIR/$filename") variables)"
}

capture_env portainer_edge_agent portainer-edge.env \
    EDGE_KEY EDGE_INSECURE_POLL EDGE EDGE_ID
capture_env plex plex.env \
    TZ VERSION PLEX_CLAIM PUID PGID
capture_env ipsec-vpn-server ipsec.env \
    VPN_IPSEC_PSK VPN_USER VPN_PASSWORD VPN_DNS_NAME VPN_DNS_SRV1 VPN_DNS_SRV2
capture_env wg-easy wg-easy.env \
    WG_HOST
capture_env webtop webtop.env \
    DOCKER_MODS INSTALL_PACKAGES LC_ALL PUID PGID TZ
capture_env Rclone-backup rclone.env \
    SYNC_DEST TZ CRON FORCE_SYNC CHECK_URL SYNC_SRC

echo "Environment capture completed. Back up $ENV_DIR; never commit it."
