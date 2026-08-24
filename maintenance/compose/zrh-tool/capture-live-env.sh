#!/usr/bin/env bash
# Capture zrh-tool's operator-supplied Grafana settings without printing values.

set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }

OUT_DIR=/etc/zrh-tool-compose
TMP_FILE=$(mktemp)
trap 'rm -f "$TMP_FILE"' EXIT

docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' grafana |
  while IFS= read -r line; do
    case "$line" in
      GF_SECURITY_ADMIN_USER=*|GF_SECURITY_ADMIN_PASSWORD=*)
        printf '%s\n' "$line"
        ;;
    esac
  done > "$TMP_FILE"

grep -q '^GF_SECURITY_ADMIN_USER=' "$TMP_FILE" ||
  { echo "Grafana admin user override was not found." >&2; exit 1; }
grep -q '^GF_SECURITY_ADMIN_PASSWORD=' "$TMP_FILE" ||
  { echo "Grafana admin password override was not found." >&2; exit 1; }

install -d -m 700 "$OUT_DIR"
install -m 600 "$TMP_FILE" "$OUT_DIR/grafana.env"

echo "Captured 2 Grafana overrides in $OUT_DIR/grafana.env (values not displayed)."
