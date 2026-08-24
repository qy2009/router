#!/usr/bin/env bash
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }

target=/etc/phx-arm-compose
install -d -m 700 "$target"
umask 077

capture_env() {
  local container=$1
  local output=$2
  docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container" > "$target/$output"
  chmod 600 "$target/$output"
}

capture_env nexterm nexterm.env
capture_env frps frps.env
capture_env sub-store sub-store.env
capture_env plex plex.env
capture_env sonarr sonarr.env
capture_env immich_postgres immich-database.env
capture_env immich_machine_learning immich-machine-learning.env
capture_env webtop webtop.env

listener=$(docker inspect --format '{{index .Config.Cmd 1}}' cf-proxy)
case "$listener" in
  socks5://*) ;;
  *) echo "Unexpected cf-proxy listener format; refusing to capture." >&2; exit 1 ;;
esac
printf '%s\n' "$listener" > "$target/cf-proxy-listener"
chmod 600 "$target/cf-proxy-listener"

for file in "$target"/*; do
  printf '%s lines=%s mode=%s\n' "$(basename "$file")" "$(wc -l < "$file")" "$(stat -c %a "$file")"
done
