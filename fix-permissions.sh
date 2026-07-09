#!/usr/bin/env bash
# fix-permissions.sh – Ensure Nextcloud bind mount permissions are correct
#
# Run this script after reboots or container restarts to maintain proper permissions.
# It uses setgid bit to ensure group ownership persists for new files.
#
# Usage: ./fix-permissions.sh

set -euo pipefail

DATA_DIR="${HOME}/Dropbox/backups/used-for-recovery/linux/services/nextcloud/data"

echo "Fixing Nextcloud permissions in: ${DATA_DIR}"

# Fix app and userdata directories with setgid bit
echo "  Setting setgid bit and group permissions on app/..."
chmod -R g+s,g+rwX "${DATA_DIR}/app" 2>/dev/null || true
find "${DATA_DIR}/app" -type f -exec chmod g+rw {} \; 2>/dev/null || true

echo "  Setting setgid bit and group permissions on userdata/..."
chmod -R g+s,g+rwX "${DATA_DIR}/userdata" 2>/dev/null || true
find "${DATA_DIR}/userdata" -type f -exec chmod g+rw {} \; 2>/dev/null || true

# Try to fix db if running as root
if [[ "$EUID" -eq 0 ]]; then
    echo "  Setting permissions on db/ (running as root)..."
    chmod -R g+s,g+rwX "${DATA_DIR}/db" 2>/dev/null || true
else
    echo "  Skipping db/ (requires root; it's typically read-only for backup purposes)"
fi

echo "✓ Permissions fixed successfully!"
echo ""
echo "To automate this after reboot, add to your crontab:"
echo "  @reboot sleep 10 && ${PWD}/fix-permissions.sh"
