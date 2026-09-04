#!/usr/bin/env bash
# rescan-files.sh
#
# Rescans Nextcloud's filesystem index (`occ files:scan`) so files that were
# added/changed directly on disk (bypassing the web UI/sync client -- e.g.
# restored from a backup, copied in manually, or fixed up after the DB
# repair/migration) show up for the user in the Nextcloud UI.
#
# Usage:
#   ./rescan-files.sh              # rescan all users
#   ./rescan-files.sh shalom       # rescan just user "shalom"
#   ./rescan-files.sh alice bob    # rescan multiple specific users
#
# occ must run as the same uid that owns config/config.php inside the
# container (usually the host user who ran install.sh, not www-data) --
# this script detects that uid automatically so you don't have to.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if docker compose version &>/dev/null 2>&1; then
    COMPOSE="docker compose"
elif command -v docker-compose &>/dev/null; then
    COMPOSE="docker-compose"
else
    echo "ERROR: Docker Compose not found." >&2
    exit 1
fi

CONTAINER="nextcloud-setup-nextcloud-1"
LOG_TAG="[rescan-files]"

log() { echo "$(date '+%F %T') ${LOG_TAG} $*"; }

if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
    echo "ERROR: ${CONTAINER} is not running. Start the stack first: ${COMPOSE} up -d" >&2
    exit 1
fi

# Detect the uid that owns config.php (occ refuses to run as any other user).
OCC_UID=$(docker exec "$CONTAINER" stat -c '%u' /var/www/html/config/config.php 2>/dev/null || echo "")
if [[ -z "$OCC_UID" ]]; then
    log "Could not detect config.php owner; falling back to www-data."
    OCC_UID="www-data"
fi

run_occ() {
    docker exec --user "$OCC_UID" "$CONTAINER" php occ "$@"
}

if [[ $# -eq 0 ]]; then
    log "Rescanning files for ALL users (this may take a while for large libraries)..."
    run_occ files:scan --all
else
    log "Rescanning files for user(s): $*"
    run_occ files:scan "$@"
fi

log "Done."
