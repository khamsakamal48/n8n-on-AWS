#!/usr/bin/env bash
# =============================================================================
# Enable Auto-Start for n8n Podman Stack
# =============================================================================
# This script installs and enables the systemd service that starts the n8n
# production stack automatically on system boot.
#
# Usage:
#   ./enable-autostart.sh
#
# What it does:
#   1. Copies n8n-stack.service to /etc/systemd/system/
#   2. Reloads systemd daemon
#   3. Enables the service to start on boot
#   4. Shows service status
#
# To test without rebooting:
#   sudo systemctl start n8n-stack.service
#
# To disable auto-start:
#   sudo systemctl disable n8n-stack.service
# =============================================================================

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log()  { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
error() { echo -e "${RED}✗${NC} $*" >&2; }

# --- Preflight Checks ---

if [[ $EUID -eq 0 ]]; then
    error "Do NOT run this script as root. It will use sudo when needed."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_FILE="$SCRIPT_DIR/systemd/n8n-stack.service"
DEPLOY_DIR="/opt/n8n-production"

if [[ ! -f "$SERVICE_FILE" ]]; then
    error "Service file not found: $SERVICE_FILE"
    exit 1
fi

if [[ ! -d "$DEPLOY_DIR" ]]; then
    error "Deployment directory not found: $DEPLOY_DIR"
    error "Please run deploy.sh first to set up the n8n stack."
    exit 1
fi

if [[ ! -f "$DEPLOY_DIR/.env" ]]; then
    error ".env file not found in $DEPLOY_DIR"
    error "Please ensure the n8n stack is properly deployed."
    exit 1
fi

# Check if podman-compose is available
if ! command -v podman-compose &>/dev/null; then
    error "podman-compose is not installed or not in PATH"
    exit 1
fi

echo "============================================="
echo "  n8n Stack Auto-Start Configuration"
echo "============================================="
echo ""

# --- Install Service ---

log "Installing systemd service..."
# Substitute the current user and group into the service file
# This ensures the service runs as the same user who deployed the containers
CURRENT_USER="$(id -un)"
CURRENT_GROUP="$(id -gn)"

log "Configuring service to run as user: $CURRENT_USER (group: $CURRENT_GROUP)"
sed "s/__DEPLOY_USER__/${CURRENT_USER}/g; s/__DEPLOY_GROUP__/${CURRENT_GROUP}/g" \
    "$SERVICE_FILE" | sudo tee /etc/systemd/system/n8n-stack.service >/dev/null

# Enable lingering so /run/user/<UID> is created at boot (not just on login).
# Rootless Podman needs this directory for its runtime socket and storage.
sudo loginctl enable-linger "$CURRENT_USER"
log "Enabled linger for $CURRENT_USER (ensures /run/user/$(id -u) exists at boot)"

log "Reloading systemd daemon..."
sudo systemctl daemon-reload

log "Enabling n8n-stack.service to start on boot..."
sudo systemctl enable n8n-stack.service

echo ""
log "Auto-start enabled successfully!"
echo ""
echo "  Service:       n8n-stack.service"
echo "  Status:        sudo systemctl status n8n-stack.service"
echo "  Start now:     sudo systemctl start n8n-stack.service"
echo "  Stop:          sudo systemctl stop n8n-stack.service"
echo "  Restart:       sudo systemctl restart n8n-stack.service"
echo "  Disable:       sudo systemctl disable n8n-stack.service"
echo "  Logs:          sudo journalctl -u n8n-stack.service -f"
echo ""

# --- Check Current Status ---

echo "Current service status:"
echo ""
sudo systemctl status n8n-stack.service --no-pager || true

echo ""
echo "============================================="
warn "The service is now enabled but NOT started yet."
echo ""
echo "To test the auto-start without rebooting:"
echo "  1. Stop the stack:  cd $DEPLOY_DIR && podman-compose down"
echo "  2. Start via systemd: sudo systemctl start n8n-stack.service"
echo "  3. Check status:    sudo systemctl status n8n-stack.service"
echo ""
echo "On next system reboot, the stack will start automatically."
echo "============================================="
