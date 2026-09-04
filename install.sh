#!/usr/bin/env bash
# install.sh – Bootstrap Nextcloud + Collabora Online in Docker
#
# Usage:
#   chmod +x install.sh && ./install.sh
#
# Environment overrides (set before running):
#   NEXTCLOUD_PORT   Host port for Nextcloud  (default: 8080)
#   COLLABORA_PORT   Host port for Collabora  (default: 9980)
#
# Data is persisted at $HOME/Dropbox/backups/used-for-recovery/linux/services/nextcloud/data, sub-divided as:
#   app/       – Nextcloud application files (config, apps, themes)
#   userdata/  – User documents and files  ← primary backup target
#   backups/db/ – Daily MariaDB dumps (see backup-db.sh)
#
# MariaDB's live data directory is stored OUTSIDE of DATA_DIR (see DB_DATA_DIR
# below), because Dropbox syncing live database files mid-write corrupts them.

set -euo pipefail

# ── Paths ──────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${HOME}/Dropbox/backups/used-for-recovery/linux/services/nextcloud/data"
# MUST be outside any Dropbox/cloud-sync path -- see the note in .env.
DB_DATA_DIR="${DB_DATA_DIR:-/var/lib/nextcloud-db}"
ENV_FILE="${SCRIPT_DIR}/.env"

# ── Helpers ────────────────────────────────────────────────────────────────────
log()  { printf '\e[32m[%s]\e[0m %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '\e[33m[WARN %s]\e[0m %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()  { printf '\e[31m[ERROR]\e[0m %s\n' "$*" >&2; exit 1; }
sep()  { printf '%0.s─' {1..60}; printf '\n'; }

gen_pass() {
    # 32-char password from the OS random source; no shell-special chars
    # Run in subshell with pipefail disabled to prevent SIGPIPE exit
    (set +o pipefail; tr -dc 'A-Za-z0-9_@%&*-' </dev/urandom | head -c 32)
}

# ── Pre-flight checks ──────────────────────────────────────────────────────────
for cmd in docker awk sed tr cut; do
    command -v "${cmd}" &>/dev/null || die "Required command '${cmd}' not found."
done

docker info &>/dev/null || die "Docker daemon is not running. Start Docker and retry."

if docker compose version &>/dev/null 2>&1; then
    COMPOSE="docker compose"
elif command -v docker-compose &>/dev/null; then
    COMPOSE="docker-compose"
else
    die "Docker Compose not found. Install Docker Compose v2 and retry."
fi

log "Compose command: ${COMPOSE}"

# ── Detect host IP ─────────────────────────────────────────────────────────────
HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[[ -n "${HOST_IP:-}" ]] || HOST_IP="localhost"
log "Host IP detected: ${HOST_IP}"

# Port config (allow caller to override via environment)
NEXTCLOUD_PORT="${NEXTCLOUD_PORT:-8080}"
COLLABORA_PORT="${COLLABORA_PORT:-9980}"

# ── Create data directories ────────────────────────────────────────────────────
log "Creating data directories under: ${DATA_DIR}"
mkdir -p "${DATA_DIR}/app" "${DATA_DIR}/userdata" "${DATA_DIR}/backups/db"

# DB_DATA_DIR (e.g. /var/lib/nextcloud-db) is typically outside the caller's
# home directory and not writable by this user. Create it via a throwaway
# container instead of `mkdir`/`sudo` -- Docker's bind-mount logic creates
# the host path as root (owned by the daemon) with no privilege prompt.
if [[ ! -d "${DB_DATA_DIR}" ]]; then
    log "Creating database data directory: ${DB_DATA_DIR} (via Docker, no sudo needed)"
    docker run --rm -v "${DB_DATA_DIR}:/data" alpine true
fi

# ── Generate .env ──────────────────────────────────────────────────────────────
if [[ -f "${ENV_FILE}" ]]; then
    log ".env already exists – skipping credential generation."
    # Read existing admin credentials for the summary at the end
    NC_ADMIN_USER=$(grep -E '^NEXTCLOUD_ADMIN_USER=' "${ENV_FILE}" | cut -d= -f2- | tr -d '"')
    NC_ADMIN_PASS=$(grep -E '^NEXTCLOUD_ADMIN_PASSWORD=' "${ENV_FILE}" | cut -d= -f2- | tr -d '"')

    # Backfill DB_DATA_DIR into pre-existing .env files that predate it.
    if ! grep -qE '^DB_DATA_DIR=' "${ENV_FILE}"; then
        log "Adding DB_DATA_DIR=${DB_DATA_DIR} to existing .env …"
        cat >> "${ENV_FILE}" <<EOF

# ── Database data directory ───────────────────────────────────────────────────
# MUST be OUTSIDE any Dropbox/cloud-sync path. Dropbox syncing live MariaDB
# files (ibdata1, ib_logfile0, aria_log, binlog) mid-write corrupts them and
# causes crash loops on every reboot. Backups of the DB are instead produced
# by backup-db.sh as a clean mysqldump written into DATA_DIR.
DB_DATA_DIR=${DB_DATA_DIR}
EOF
    fi
else
    log "Generating ${ENV_FILE} with random credentials …"

    # Generate all secrets up front
    NC_ADMIN_USER="admin"
    NC_ADMIN_PASS="$(gen_pass)"
    MYSQL_ROOT_PASS="$(gen_pass)"
    MYSQL_PASS="$(gen_pass)"
    COLLAB_ADMIN_USER="admin"
    COLLAB_ADMIN_PASS="$(gen_pass)"

    # Escape dots in the IP to build a valid regex for Collabora's aliasgroup1
    ESCAPED_IP=$(printf '%s' "${HOST_IP}" | sed 's/\./\\./g')
    WOPI_DOMAIN="http://${ESCAPED_IP}:${NEXTCLOUD_PORT}"

    cat > "${ENV_FILE}" <<EOF
# ── Image versions ────────────────────────────────────────────────────────────
# Pin to specific versions for reproducible deployments.
MARIADB_IMAGE=mariadb:10.11
NEXTCLOUD_IMAGE=nextcloud:30-apache
COLLABORA_IMAGE=collabora/code:latest

# ── Data directory ────────────────────────────────────────────────────────────
DATA_DIR=${DATA_DIR}

# ── Database data directory ───────────────────────────────────────────────────
# MUST be OUTSIDE any Dropbox/cloud-sync path. Dropbox syncing live MariaDB
# files (ibdata1, ib_logfile0, aria_log, binlog) mid-write corrupts them and
# causes crash loops on every reboot. Backups of the DB are instead produced
# by backup-db.sh as a clean mysqldump written into DATA_DIR.
DB_DATA_DIR=${DB_DATA_DIR}

# ── Host ports ────────────────────────────────────────────────────────────────
NEXTCLOUD_PORT=${NEXTCLOUD_PORT}
COLLABORA_PORT=${COLLABORA_PORT}

# ── Nextcloud admin account ───────────────────────────────────────────────────
NEXTCLOUD_ADMIN_USER=${NC_ADMIN_USER}
NEXTCLOUD_ADMIN_PASSWORD=${NC_ADMIN_PASS}

# Trusted domains: space-separated list of hostnames / IPs the web UI is served from.
# Add your server's domain name here if you later put it behind a reverse proxy.
NEXTCLOUD_TRUSTED_DOMAINS="${HOST_IP} localhost"

# ── Database credentials ──────────────────────────────────────────────────────
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASS}
MYSQL_PASSWORD=${MYSQL_PASS}

# ── Collabora admin account ───────────────────────────────────────────────────
COLLABORA_ADMIN_USER=${COLLAB_ADMIN_USER}
COLLABORA_ADMIN_PASSWORD=${COLLAB_ADMIN_PASS}

# Regex matching the Nextcloud URL used by Collabora's WOPI allow-list.
# Dots are escaped (\.) because this is treated as a regular expression.
# Update this if Nextcloud is accessed via a domain name instead of an IP.
NEXTCLOUD_WOPI_DOMAIN=${WOPI_DOMAIN}
EOF

    chmod 600 "${ENV_FILE}"
    log ".env written (mode 600)."
fi

# ── Pull images & start containers ────────────────────────────────────────────
cd "${SCRIPT_DIR}"

log "Pulling Docker images …"
${COMPOSE} pull

log "Starting services …"
${COMPOSE} up -d

# ── Wait for Nextcloud first-run setup to complete ────────────────────────────
log "Waiting for Nextcloud to complete initial installation (≈1–3 min) …"
WAITED=0
MAX_WAIT=360  # 6 minutes

until ${COMPOSE} exec --no-TTY --user www-data nextcloud \
        php occ status --output=json 2>/dev/null | grep -q '"installed":true'; do
    WAITED=$((WAITED + 5))
    if [[ ${WAITED} -gt ${MAX_WAIT} ]]; then
        die "Nextcloud did not finish setup within ${MAX_WAIT}s.
  Check container logs:  ${COMPOSE} logs -f nextcloud"
    fi
    printf '.'
    sleep 5
done
printf '\n'
log "Nextcloud is installed and running."

# ── Install & enable Nextcloud Office (Collabora integration) ────────────────
log "Installing Nextcloud Office app (richdocuments) …"

# app:install is a no-op (exits non-zero) if the app is already present;
# we then fall back to app:enable in case it was installed but disabled.
if ! ${COMPOSE} exec --no-TTY --user www-data nextcloud \
        php occ app:install richdocuments 2>/dev/null; then
    warn "app:install returned non-zero (app may already be installed). Enabling instead …"
fi

if ! ${COMPOSE} exec --no-TTY --user www-data nextcloud \
        php occ app:enable richdocuments 2>/dev/null; then
    warn "Could not enable richdocuments. You may need to install it manually via
  Nextcloud → Apps → Office & Text → Nextcloud Office."
fi

# ── Point Nextcloud Office at the Collabora server ───────────────────────────
COLLAB_URL="http://${HOST_IP}:${COLLABORA_PORT}"
log "Setting Collabora server URL → ${COLLAB_URL}"

${COMPOSE} exec --no-TTY --user www-data nextcloud \
    php occ config:app:set richdocuments wopi_url --value="${COLLAB_URL}"

# ── Derive the Docker network subnet for the WOPI allow-list ─────────────────
# Collabora contacts Nextcloud via WOPI; Nextcloud must trust that source IP.
COLLAB_CONTAINER_ID=$(${COMPOSE} ps -q collabora 2>/dev/null || echo "")
DOCKER_SUBNET=""

if [[ -n "${COLLAB_CONTAINER_ID}" ]]; then
    COLLAB_IP=$(docker inspect \
        --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
        "${COLLAB_CONTAINER_ID}" 2>/dev/null || echo "")
    if [[ -n "${COLLAB_IP}" ]]; then
        OCTET123=$(printf '%s' "${COLLAB_IP}" | cut -d. -f1-3)
        DOCKER_SUBNET="${OCTET123}.0/24"
    fi
fi

if [[ -z "${DOCKER_SUBNET}" ]]; then
    DOCKER_SUBNET="172.16.0.0/12"
    warn "Could not detect Collabora container IP; using ${DOCKER_SUBNET} for WOPI allowlist."
fi

log "Setting WOPI allowlist → ${DOCKER_SUBNET}"
${COMPOSE} exec --no-TTY --user www-data nextcloud \
    php occ config:app:set richdocuments wopi_allowlist --value="${DOCKER_SUBNET}"

# ── Final cache flush ─────────────────────────────────────────────────────────
log "Flushing Nextcloud caches …"
${COMPOSE} exec --no-TTY --user www-data nextcloud php occ cache:flush 2>/dev/null || true

# ── Fix file permissions (setgid for bind mounts) ──────────────────────────────
log "Fixing bind mount permissions (setgid bit) …"
log "  Setting group ownership and sticky bit on app/ …"
chmod -R g+s,g+rwX "${DATA_DIR}/app" 2>/dev/null || true
find "${DATA_DIR}/app" -type f -exec chmod g+rw {} \; 2>/dev/null || true

log "  Setting group ownership and sticky bit on userdata/ …"
chmod -R g+s,g+rwX "${DATA_DIR}/userdata" 2>/dev/null || true
find "${DATA_DIR}/userdata" -type f -exec chmod g+rw {} \; 2>/dev/null || true

# ── Setup automatic permission fix after reboot ──────────────────────────────────
log "Setting up automatic permission fix after reboot …"
CRON_ENTRY="@reboot sleep 10 && ${SCRIPT_DIR}/fix-permissions.sh"
if ! crontab -l 2>/dev/null | grep -q "fix-permissions.sh"; then
    (crontab -l 2>/dev/null; echo "${CRON_ENTRY}") | crontab -
    log "✓ Crontab entry added: permissions will be fixed automatically after reboot"
else
    log "✓ Crontab entry already exists"
fi

# ── Install systemd units: DB repair-at-boot + daily DB backup ───────────────
# repair-db.sh fixes the MariaDB "Aria recovery failed" crash loop that can
# occur after an unclean shutdown/reboot. backup-db.sh takes a daily
# mysqldump into DATA_DIR/backups/db (safe to sync via Dropbox, unlike the
# live DB files in DB_DATA_DIR). Both need root to install (writes under
# /etc/systemd/system), so this step will prompt for your sudo password.
CURRENT_USER="$(id -un)"

if ! command -v systemctl &>/dev/null; then
    warn "systemctl not found (no systemd on this host) – skipping automatic DB"
    warn "repair/backup unit installation. Run these manually as needed:"
    warn "  ${SCRIPT_DIR}/repair-db.sh   (after every reboot)"
    warn "  ${SCRIPT_DIR}/backup-db.sh   (daily)"
elif ! sudo -v 2>/dev/null; then
    warn "Could not obtain sudo – skipping automatic DB repair/backup unit installation."
    warn "Re-run install.sh with sudo access, or install these systemd units manually"
    warn "(see the commented instructions at the bottom of repair-db.sh / backup-db.sh)."
else
    log "Installing nextcloud-db-repair.service (runs repair-db.sh once per boot) …"
    sudo tee /etc/systemd/system/nextcloud-db-repair.service >/dev/null <<EOF
[Unit]
Description=Repair Nextcloud MariaDB after unclean shutdown
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
ExecStart=${SCRIPT_DIR}/repair-db.sh
User=${CURRENT_USER}

[Install]
WantedBy=multi-user.target
EOF

    log "Installing nextcloud-db-backup.service + .timer (runs backup-db.sh daily) …"
    sudo tee /etc/systemd/system/nextcloud-db-backup.service >/dev/null <<EOF
[Unit]
Description=Backup Nextcloud MariaDB to Dropbox
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=${SCRIPT_DIR}/backup-db.sh
User=${CURRENT_USER}
EOF

    sudo tee /etc/systemd/system/nextcloud-db-backup.timer >/dev/null <<EOF
[Unit]
Description=Run Nextcloud DB backup daily

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now nextcloud-db-repair.service
    sudo systemctl enable --now nextcloud-db-backup.timer
    log "✓ nextcloud-db-repair.service enabled (runs at every boot)"
    log "✓ nextcloud-db-backup.timer enabled (runs backup-db.sh daily)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
sep
printf '  \e[1mNextcloud is ready!\e[0m\n\n'
printf '  %-22s \e[36m%s\e[0m\n'  "Nextcloud URL:"   "http://${HOST_IP}:${NEXTCLOUD_PORT}"
printf '  %-22s %s\n'             "Admin username:"  "${NC_ADMIN_USER:-admin}"
printf '  %-22s %s\n'             "Admin password:"  "${NC_ADMIN_PASS:-(see ${ENV_FILE})}"
echo ""
printf '  %-22s \e[36m%s\e[0m\n'  "Collabora admin UI:" \
    "http://${HOST_IP}:${COLLABORA_PORT}/browser/dist/admin/admin.html"
echo ""
printf '  %-22s %s\n'  "Persistent data:" "${DATA_DIR}"
printf '  %-22s %s\n'  "DB data (local):" "${DB_DATA_DIR}"
echo ""
printf '  \e[2mTo stop :\e[0m  %s\n'   "${COMPOSE} -f '${SCRIPT_DIR}/docker-compose.yml' down"
printf '  \e[2mTo start:\e[0m  %s\n'   "${COMPOSE} -f '${SCRIPT_DIR}/docker-compose.yml' up -d"
printf '  \e[2mBackup  :\e[0m  %s\n'   "tar -czf nextcloud-backup-\$(date +%F).tar.gz '${DATA_DIR}'"
echo ""
printf '  \e[2mTo fix permissions after reboot:\e[0m  %s\n' "'${SCRIPT_DIR}/fix-permissions.sh'"
printf '  \e[2mDB self-repair after reboot   :\e[0m  %s\n' "nextcloud-db-repair.service (systemd, auto)"
printf '  \e[2mDB daily backup                :\e[0m  %s\n' "nextcloud-db-backup.timer (systemd, auto)"
printf '  \e[2mCredentials are stored in: %s\e[0m\n' "${ENV_FILE}"
sep
