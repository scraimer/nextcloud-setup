#!/usr/bin/env bash
# repair-db.sh
#
# Detects and repairs the MariaDB "Aria recovery failed" crash loop, then
# makes sure the stack is running. Safe to run any time (idempotent) and
# intended to run automatically at every boot as a safety net (see install
# instructions at the bottom of this file).
#
# Root cause (fixed permanently by migrate-db-storage.sh): the DB data
# directory used to live inside a Dropbox-synced folder. Dropbox syncing
# live, open database files corrupted MariaDB's Aria storage-engine log
# (and left behind "conflicted copy" duplicate files), so on every boot
# mariadbd aborted with:
#   "Aria recovery failed. Please run aria_chk -r on all Aria tables
#    (*.MAI) and delete all aria_log.######## files"
#
# This script does NOT touch the host filesystem directly -- the data
# directory (Dropbox path or the new local /var/lib/nextcloud-db) is not
# writable by a non-root host user. Instead it uses a throwaway container
# bind-mounted to the same Docker volume the db service uses, so cleanup
# always runs as root regardless of host file ownership/permissions.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

CONTAINER="nextcloud-setup-db-1"
LOG_TAG="[repair-db]"
MAX_WAIT=60

log() { echo "$(date '+%F %T') ${LOG_TAG} $*"; }

wait_for_container_state() {
  local waited=0
  while (( waited < MAX_WAIT )); do
    local status
    status=$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo "missing")
    case "$status" in
      running)
        local health
        health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER" 2>/dev/null)
        [[ "$health" == "healthy" || "$health" == "none" ]] && return 0
        ;;
      restarting) : ;; # keep waiting
      missing) return 2 ;;
    esac
    sleep 2
    ((waited += 2))
  done
  return 1
}

log "Checking database container health..."

if wait_for_container_state; then
  log "Database is healthy. Nothing to repair."
  exit 0
fi

log "Database did not become healthy within ${MAX_WAIT}s -- checking logs for Aria corruption..."
if ! docker logs --tail 50 "$CONTAINER" 2>&1 | grep -q "Aria recovery failed"; then
  log "Container unhealthy for a reason other than Aria recovery; not touching data. Recent logs:"
  docker logs --tail 30 "$CONTAINER" 2>&1 | sed "s/^/${LOG_TAG} | /"
  exit 1
fi

# Find the actual Docker volume backing the db service's /var/lib/mysql,
# whatever host path it currently binds to.
VOLUME=$(docker inspect -f '{{ range .Mounts }}{{ if eq .Destination "/var/lib/mysql" }}{{ .Name }}{{ end }}{{ end }}' "$CONTAINER" 2>/dev/null)
if [[ -z "$VOLUME" ]]; then
  log "Could not determine the db data volume; aborting."
  exit 1
fi

log "Confirmed: Aria recovery failure. Repairing by clearing the Aria log (system tables only, no Nextcloud data is stored via Aria) in volume '${VOLUME}'."
docker compose stop db

docker run --rm -v "${VOLUME}:/data" alpine sh -c '
  rm -f /data/aria_log.* /data/aria_log_control
  find /data -iname "*conflicted copy*" -delete
'

log "Restarting db..."
docker compose up -d db

if wait_for_container_state; then
  log "Repair successful, database is healthy."
  # Bring the rest of the stack up too, in case it was waiting on db.
  docker compose up -d
  exit 0
else
  log "Repair FAILED -- database still not healthy. Manual investigation required:"
  docker logs --tail 50 "$CONTAINER" 2>&1 | sed "s/^/${LOG_TAG} | /"
  exit 1
fi

# ── Installed as a boot-time safety net ──────────────────────────────────────
# install.sh installs and enables the "nextcloud-db-repair.service" systemd
# unit automatically (runs this script once at every boot, after Docker is
# up). Re-run install.sh to (re)install it, or see it directly:
#   systemctl status nextcloud-db-repair.service
#   systemctl cat nextcloud-db-repair.service
