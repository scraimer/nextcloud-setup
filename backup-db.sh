#!/usr/bin/env bash
# backup-db.sh
#
# Produces a consistent logical backup (mysqldump) of the Nextcloud database
# and writes it as a single, complete, closed file into the Dropbox-synced
# DATA_DIR/backups/db directory. This is the SAFE way to get the DB into
# Dropbox: the dump file is only ever written once and then closed, so
# Dropbox syncing it afterwards cannot race with a live writer (unlike the
# live MariaDB data files, which must never live in a synced folder --
# see repair-db.sh and migrate-db-storage.sh).
#
# Intended to run daily via systemd timer / cron (see bottom of this file).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# Load .env safely: values (passwords) may contain shell-special characters
# (&, $, etc.), so this must NOT be executed as shell code via `source`.
while IFS='=' read -r key value; do
  [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
  printf -v "$key" '%s' "$value"
  export "$key"
done < <(grep -v '^\s*#' .env | grep '=')

RETENTION_DAYS="${DB_BACKUP_RETENTION_DAYS:-14}"
BACKUP_DIR="${DATA_DIR}/backups/db"
CONTAINER="nextcloud-setup-db-1"
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
OUT_FILE="${BACKUP_DIR}/nextcloud-db-${TIMESTAMP}.sql.gz"
LOG_TAG="[backup-db]"

log() { echo "$(date '+%F %T') ${LOG_TAG} $*"; }

mkdir -p "$BACKUP_DIR"

if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
  log "ERROR: db container is not running; skipping backup."
  exit 1
fi

log "Dumping database to ${OUT_FILE}..."
TMP_FILE="${OUT_FILE}.tmp"
ERR_FILE="$(mktemp)"
# --force: keep dumping remaining tables even if one table errors out (e.g. a
# table with a corrupted engine dictionary entry). We check the actual output
# file, not mysqldump's exit code, so one bad table doesn't block the backup
# of everything else. `set -o pipefail` is disabled just for this pipeline.
set +o pipefail
docker exec "$CONTAINER" sh -c \
    "exec mysqldump -u root -p'${MYSQL_ROOT_PASSWORD}' --single-transaction --routines --triggers --force --all-databases" \
    2> "$ERR_FILE" | gzip > "$TMP_FILE"
set -o pipefail

if [[ -s "$ERR_FILE" ]]; then
  log "mysqldump reported warnings/errors (see below); continuing if a dump was produced:"
  sed "s/^/${LOG_TAG} | /" "$ERR_FILE"
fi
rm -f "$ERR_FILE"

if [[ -s "$TMP_FILE" ]] && gzip -t "$TMP_FILE" 2>/dev/null; then
  mv "$TMP_FILE" "$OUT_FILE"
  log "Backup succeeded: $(du -h "$OUT_FILE" | cut -f1)"
else
  log "ERROR: mysqldump produced no usable output."
  rm -f "$TMP_FILE"
  exit 1
fi

log "Pruning backups older than ${RETENTION_DAYS} days..."
find "$BACKUP_DIR" -name 'nextcloud-db-*.sql.gz' -mtime "+${RETENTION_DAYS}" -print -delete

log "Done."

# ── Installed as a daily systemd timer ───────────────────────────────────────
# install.sh installs and enables the "nextcloud-db-backup.timer" systemd
# unit automatically (runs this script daily). Re-run install.sh to
# (re)install it, or see it directly:
#   systemctl status nextcloud-db-backup.timer
#   systemctl list-timers nextcloud-db-backup.timer
#

