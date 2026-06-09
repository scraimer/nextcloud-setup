# Nextcloud + Collabora (Docker)

This project installs a self-hosted Nextcloud instance with Collabora Online for WYSIWYG document editing.

Persistent data is stored on the host at:

- `$HOME/services/nextcloud/data`

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
tar -czf nextcloud-backup-$(date +%F).tar.gz "$HOME/services/nextcloud/data"
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

## Notes

- Credentials are stored in `.env` (created by `install.sh`).
- Keep `.env` and `$HOME/services/nextcloud/data` in your backup strategy.
