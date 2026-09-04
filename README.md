# Nextcloud + Collabora (Docker)

This project installs a self-hosted Nextcloud instance with Collabora Online for WYSIWYG document editing.

Persistent data is stored on the host at:

- `$HOME/Dropbox/backups/used-for-recovery/linux/services/nextcloud/data`

Docker named volumes (with `driver: local` / `type: none` bind mounts) are used so that
files are stored at the above host path while Docker tracks the volume lifecycle.

## Prerequisites

- Linux host
- Docker Engine running
- Docker Compose v2 (`docker compose`)

## Install Docker Compose v2

On Linux Mint / Ubuntu:

```bash
sudo apt-get update
sudo apt-get install -y docker-compose-v2
docker compose version
```

If `docker compose version` prints a version, Compose v2 is installed correctly.

## Quick Start

From this folder:

```bash
chmod +x install.sh
./install.sh
```

The script will:

1. Create host data directories under `$HOME/services/nextcloud/data`
2. Generate a `.env` file with credentials
3. Start `db`, `nextcloud`, and `collabora` containers
4. Configure Nextcloud Office integration (Collabora)

## Open the Services

After installation, open:

- Nextcloud: `http://<YOUR_HOST_IP>:8080`
- Collabora admin UI: `http://<YOUR_HOST_IP>:9980/browser/dist/admin/admin.html`

The script prints the detected host IP and generated admin credentials when it finishes.

## Optional Port Overrides

You can override default ports at execution time:

```bash
NEXTCLOUD_PORT=8080 COLLABORA_PORT=9980 ./install.sh
```

## Daily Operations

### Starting on Host Boot (Reboot)
All containers are configured with `restart: unless-stopped` policies. If your system reboots, Docker will **automatically start** Nextcloud, MariaDB, and Collabora back up once the Docker daemon is online.

### Manual commands
Start services:

```bash
docker compose up -d
```

Stop services:

```bash
docker compose down
```

View logs:

```bash
docker compose logs -f
```

## Backup and Restore

Create a backup archive:

```bash
tar -czf nextcloud-backup-$(date +%F).tar.gz "$HOME/Dropbox/backups/used-for-recovery/linux/services/nextcloud/data"
```

Restore from backup (example):

```bash
# Stop stack first
docker compose down

# Extract over the data directory
tar -xzf nextcloud-backup-YYYY-MM-DD.tar.gz -C /

# Start again
docker compose up -d
```

## Check logs

```shell
docker compose exec -T nextcloud tail -200 /var/www/html/data/nextcloud.log
```

## Fixing Permission Issues After Reboot

If you see "Cannot write into 'config' directory" errors after a reboot, this is likely a file permissions issue. The containers will auto-start via `restart: unless-stopped`, but if file permissions become restrictive, Nextcloud cannot function.

### Quick Fix

```bash
./fix-permissions.sh
```

### Understanding the Issue

When Docker restarts containers and remounts bind volumes, the host-level filesystem permissions apply inside the container. If files are not group-writable, the web server (Apache) cannot modify them.

### Permanent Solution

The `fix-permissions.sh` script sets the **setgid bit** on directories. This ensures that all new files created within those directories automatically inherit the group ownership (`www-data`) and group-write permissions, even after container restarts.

#### Auto-fix After Reboot

Add to your crontab to run the fix script automatically after each reboot:

```bash
crontab -e
# Add this line:
@reboot sleep 10 && /home/shalom/Dropbox/backups/used-for-recovery/linux/services/nextcloud/nextcloud-setup/fix-permissions.sh
```

This waits 10 seconds for the system to settle and Docker to start containers, then fixes permissions.

## Database Storage & Reliability

MariaDB's live data directory is **not** stored under the Dropbox-synced
`data/` folder. Dropbox syncing files while MariaDB has them open for writing
(`ibdata1`, `ib_logfile0`, `aria_log`, `binlog`) corrupts them and causes a
crash loop after every reboot ("Aria recovery failed"). Instead:

- Live DB files live at `DB_DATA_DIR` (set in `.env`, default
  `/var/lib/nextcloud-db`) — a local-only path never synced by Dropbox.
- A daily `mysqldump` snapshot is written to `data/backups/db/` instead —
  safe to sync because it's a single, complete, closed file.

`install.sh` sets this up automatically, including two systemd units:

- `nextcloud-db-repair.service` — runs `repair-db.sh` once at every boot as
  a safety net; detects and self-heals the Aria crash loop if it recurs.
- `nextcloud-db-backup.timer` — runs `backup-db.sh` once a day.

### `repair-db.sh`

Detects the MariaDB "Aria recovery failed" crash loop and repairs it
in-place (clears the corrupted Aria log via a throwaway container, restarts
the `db` service). Safe to run any time — it's a no-op if the database is
already healthy.

```bash
./repair-db.sh
```

Check the boot-time safety net:

```bash
systemctl status nextcloud-db-repair.service
```

### `migrate-db-storage.sh`

One-time migration that moves MariaDB's live data out of the Dropbox-synced
`data/db` path into `DB_DATA_DIR`, and repoints the Docker volume. Already
run once for this install; kept for reference/other machines. Idempotent —
it's a no-op if the volume already points at `DB_DATA_DIR`.

```bash
./migrate-db-storage.sh
```

### `backup-db.sh`

Produces a daily `mysqldump` (gzip-compressed) into `data/backups/db/`, and
prunes dumps older than `DB_BACKUP_RETENTION_DAYS` (default: 14 days, set in
`.env`).

```bash
./backup-db.sh
```

Check the daily timer:

```bash
systemctl list-timers nextcloud-db-backup.timer
```

## Rescanning Files

If a file exists on disk under `data/userdata/<user>/files/` but doesn't show
up in the Nextcloud web UI (e.g. after restoring from a backup, manually
copying files in, or repairing the database), Nextcloud's file index needs to
be refreshed:

```bash
./rescan-files.sh              # rescan all users
./rescan-files.sh shalom       # rescan just user "shalom"
./rescan-files.sh alice bob    # rescan multiple specific users
```

## Notes

- Credentials are stored in `.env` (created by `install.sh`).
- Keep `.env`, `$HOME/Dropbox/backups/used-for-recovery/linux/services/nextcloud/data`,
  and `DB_DATA_DIR` (default `/var/lib/nextcloud-db`) in your backup strategy.
  `DB_DATA_DIR` itself is excluded from Dropbox on purpose (see "Database
  Storage & Reliability" above) — its content is backed up daily instead via
  `backup-db.sh` into `data/backups/db/`, which *is* synced by Dropbox.
- Use `fix-permissions.sh` if permission issues arise after restarts or reboots.
- Use `repair-db.sh` if MariaDB crash-loops after a reboot.
- Use `rescan-files.sh` if files on disk aren't showing up in the Nextcloud UI.
