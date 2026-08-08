#!/bin/bash
# github-to-gdrive-backup.sh — mirrors every repo (git data) and, if
# configured, archives issues/PRs/wikis to Google Drive.
#
# Runs centrally (Unraid), not per-VPS — this is leg 4 from
# Backup-Architecture.md. GitHub is already redundant cloud infrastructure,
# so this is lower-stakes than the VPS legs; weekly is plenty.
#
# Requires: git, gh (GitHub CLI, authenticated), rclone (remote configured).

set -uo pipefail

GH_ORG_OR_USER="your-github-username"
STAGE="/mnt/user/backup-staging/github"
GDRIVE_REMOTE="gdrive-personal:Backups/GitHub"
GDRIVE_VERSIONS="gdrive-personal:Backups-versions/GitHub"
LOGFILE="/mnt/user/backup-logs/github-backup.log"
KUMA_PUSH_URL=""   # from Uptime Kuma, monitor: github-to-gdrive

exec >>"$LOGFILE" 2>&1
echo "===== GitHub backup started: $(date) ====="
mkdir -p "$STAGE"

FAILED=0
for repo in $(gh repo list "$GH_ORG_OR_USER" --limit 500 --json nameWithOwner -q '.[].nameWithOwner'); do
    name=$(basename "$repo")
    if [ -d "$STAGE/$name.git" ]; then
        git -C "$STAGE/$name.git" remote update || FAILED=1
    else
        git clone --mirror "https://github.com/$repo.git" "$STAGE/$name.git" || FAILED=1
    fi
done

# Optional: issues/PRs/wikis/releases aren't captured by `git clone --mirror`.
# Uncomment if you want them too (pip install github-backup, needs a PAT):
# github-backup "$GH_ORG_OR_USER" -t "$GITHUB_TOKEN" -o "$STAGE/../github-meta" \
#   --issues --pull-requests --wikis --labels || FAILED=1

rclone sync "$STAGE" "$GDRIVE_REMOTE" \
    --backup-dir "${GDRIVE_VERSIONS}/$(date +%F)" \
    --log-file "$LOGFILE" --log-level INFO \
    --transfers 8 --checkers 16 || FAILED=1

if [ "$FAILED" -eq 0 ]; then
    echo "Done: $(date)"
    [ -n "$KUMA_PUSH_URL" ] && curl -fsS -m 10 -G "$KUMA_PUSH_URL" --data-urlencode "status=up" --data-urlencode "msg=OK" >/dev/null
    exit 0
else
    echo "One or more steps failed — see log above."
    [ -n "$KUMA_PUSH_URL" ] && curl -fsS -m 10 -G "$KUMA_PUSH_URL" --data-urlencode "status=down" --data-urlencode "msg=repo clone or sync failed" >/dev/null
    exit 1
fi
