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

## Notes

- Credentials are stored in `.env` (created by `install.sh`).
- Keep `.env` and `$HOME/Dropbox/backups/used-for-recovery/linux/services/nextcloud/data` in your backup strategy.
- Use `fix-permissions.sh` if permission issues arise after restarts or reboots.
