#!/usr/bin/env bash
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_BIN="/usr/local/sbin/luna_backup_manager.sh"
CONFIG_DIR="/etc/luna-backup"
CONFIG_FILE="$CONFIG_DIR/luna_backup.conf"
LOG_DIR="/var/log/luna-backup"
STATE_DIR="/var/lib/luna-backup"
SERVICE_USER="luna-backup"

for t in install useradd getent awk sed grep; do command -v "$t" >/dev/null || { echo "Missing $t"; exit 1; }; done

read -r -p "Create service user $SERVICE_USER if missing? (Y/n): " x
if [ "${x:-Y}" != "n" ] && ! getent passwd "$SERVICE_USER" >/dev/null; then
  useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin "$SERVICE_USER"
fi

install -d -m 750 "$CONFIG_DIR" "$LOG_DIR" "$STATE_DIR" "$STATE_DIR/reports"
install -m 750 "$REPO_DIR/luna_backup_manager.sh" "$INSTALL_BIN"

if [ ! -f "$CONFIG_FILE" ]; then
  install -m 600 "$REPO_DIR/luna_backup.conf.example" "$CONFIG_FILE"
fi
chown -R "$SERVICE_USER":"$SERVICE_USER" "$LOG_DIR" "$STATE_DIR"

install -d -m 755 /etc/systemd/system
install -m 644 "$REPO_DIR/systemd/luna-backup.service" /etc/systemd/system/luna-backup.service
install -m 644 "$REPO_DIR/systemd/luna-backup.timer" /etc/systemd/system/luna-backup.timer

echo "Installed. Next: sudo -u $SERVICE_USER $INSTALL_BIN setup"
