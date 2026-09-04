#!/usr/bin/env bash
# migrate-db-storage.sh
#
# ONE-TIME migration: moves the live MariaDB data out of the Dropbox-synced
# DATA_DIR/db path into a local-only path (DB_DATA_DIR, set in .env, default
# /var/lib/nextcloud-db), and repoints the "db-data" Docker volume at it.
#
# WHY: Dropbox was continuously syncing the *live* database files
# (ibdata1, ib_logfile0, aria_log, binlog). Because MariaDB writes to these
# files while they are open, Dropbox's sync raced with those writes,
# truncating/replacing files mid-write and spawning "conflicted copy"
# files. This corrupted MariaDB's Aria storage-engine log, causing a crash
# loop ("Aria recovery failed") on every reboot. DB_DATA_DIR is never
# synced by Dropbox, so this cannot recur. Backups instead go through
# backup-db.sh, which writes a single, complete mysqldump file
# into DATA_DIR -- safe for Dropbox because it's closed before syncing.
#
# No sudo is required: this host user isn't in the data directory's owning
# group, but IS in the "docker" group, so we do all file operations (create
# dir, copy, chown, delete) as root *inside* throwaway containers instead.
# Run this once, interactively; it briefly stops the stack.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# Load .env safely: values (passwords) may contain shell-special characters
# (&, $, etc.), so this must NOT be executed as shell code via `source`.
while IFS='=' read -r key value; do
  [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
  printf -v "$key" '%s' "$value"
  export "$key"
done < <(grep -v '^\s*#' .env | grep '=')

NEW_DB_DIR="${DB_DATA_DIR:-/var/lib/nextcloud-db}"
OLD_VOLUME="nextcloud-setup_db-data"
CONTAINER="nextcloud-setup-db-1"

CURRENT_DEVICE=$(docker volume inspect "$OLD_VOLUME" --format '{{ index .Options "device" }}' 2>/dev/null || true)
if [[ "$CURRENT_DEVICE" == "$NEW_DB_DIR" ]]; then
  echo "Volume '${OLD_VOLUME}' already points at ${NEW_DB_DIR}; nothing to migrate."
  exit 0
fi

echo "==> Stopping the stack..."
docker compose down

echo "==> Copying data from volume '${OLD_VOLUME}' to ${NEW_DB_DIR} (as root, via a throwaway container)"
echo "    Docker will create ${NEW_DB_DIR} on the host automatically."
docker run --rm \
  -v "${OLD_VOLUME}:/old" \
  -v "${NEW_DB_DIR}:/new" \
  alpine sh -c '
    set -e
    cp -a /old/. /new/
    find /new -iname "*conflicted copy*" -delete
    # Clear the Aria recovery log too: it may already be corrupted from
    # past Dropbox syncing, and MariaDB rebuilds it cleanly on next start.
    rm -f /new/aria_log.* /new/aria_log_control
    chown -R 999:999 /new
  '

echo "==> Repointing the '${OLD_VOLUME}' volume at the new path"
docker volume rm "$OLD_VOLUME"

echo "==> Starting the stack with the new DB path"
docker compose up -d

echo "==> Waiting for db to become healthy..."
for i in $(seq 1 30); do
  status=$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo "starting")
  if [[ "$status" == "healthy" ]]; then
    echo "db is healthy."
    break
  fi
  sleep 2
done

echo
echo "Migration complete. Live DB data now lives at: ${NEW_DB_DIR} (outside Dropbox)."
echo "The old copy is still present at \${DATA_DIR}/db for safety. Once you've"
echo "confirmed Nextcloud works correctly, you may remove it (it's owned by the"
echo "container's uid, so removal also goes through a throwaway container):"
echo "  docker run --rm -v \"${DATA_DIR}/db:/old\" alpine rm -rf /old"
