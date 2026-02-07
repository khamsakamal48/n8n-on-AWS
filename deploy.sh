#!/usr/bin/env bash
# =============================================================================
# n8n Production — Fresh Deployment Script (Podman-native)
# Target: AWS EC2 t3.xlarge (4 vCPU, 16 GB RAM)
# =============================================================================
set -euo pipefail

DEPLOY_DIR="/opt/n8n-production"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

echo "============================================="
echo " n8n Production — Fresh Deployment (Podman)"
echo "============================================="
echo ""

# --- Pre-flight: Verify Podman ---
if ! command -v podman &>/dev/null; then
    err "Podman not found. Install with: sudo dnf install podman  (or apt install podman)"
fi
log "Podman found: $(podman --version)"

if command -v podman-compose &>/dev/null; then
    COMPOSE="podman-compose"
elif podman compose version &>/dev/null 2>&1; then
    COMPOSE="podman compose"
else
    err "No compose tool found. Install with: pip3 install podman-compose"
fi
log "Compose tool: $COMPOSE"

# --- Pre-flight: Verify cgroups v2 (required for resource limits) ---
if mount | grep -q "cgroup2"; then
    log "cgroups v2 detected (required for memory/CPU limits)"
else
    warn "cgroups v2 not detected. Resource limits (memory, CPU) may not work."
    echo "  Check: mount | grep cgroup"
    echo "  Enable: Add 'systemd.unified_cgroup_hierarchy=1' to kernel params"
fi

# --- Step 1: Detect Podman Socket ---
echo ""
echo "--- Step 1: Detecting Podman socket ---"

PODMAN_SOCKET=""

# Check rootful socket first (production servers typically use rootful)
if [ -S "/run/podman/podman.sock" ]; then
    PODMAN_SOCKET="/run/podman/podman.sock"
    log "Rootful Podman socket found: $PODMAN_SOCKET"
# Check rootless socket
elif [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock" ]; then
    PODMAN_SOCKET="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"
    log "Rootless Podman socket found: $PODMAN_SOCKET"
else
    warn "No Podman socket found. Enabling it now..."
    if [ "$(id -u)" -eq 0 ]; then
        systemctl enable --now podman.socket
        PODMAN_SOCKET="/run/podman/podman.sock"
    else
        systemctl --user enable --now podman.socket
        PODMAN_SOCKET="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"
        # Ensure user session persists after logout (needed for rootless)
        loginctl enable-linger "$(whoami)" 2>/dev/null || true
    fi

    if [ -S "$PODMAN_SOCKET" ]; then
        log "Podman socket enabled: $PODMAN_SOCKET"
    else
        warn "Could not enable Podman socket automatically."
        echo "  Manual fix (rootful):  sudo systemctl enable --now podman.socket"
        echo "  Manual fix (rootless): systemctl --user enable --now podman.socket"
        echo "  Watchtower will not work without the socket, but n8n will."
        PODMAN_SOCKET="/run/podman/podman.sock"  # Default, fix later
    fi
fi

# --- Step 2: Create Directory Structure ---
echo ""
echo "--- Step 2: Creating directory structure ---"
sudo mkdir -p "$DEPLOY_DIR"/{postgres/data,postgres/init,n8n/data,runners}
sudo chown -R "$(id -u):$(id -g)" "$DEPLOY_DIR"
log "Created $DEPLOY_DIR"

# --- Step 3: Copy Configuration Files ---
echo ""
echo "--- Step 3: Copying configuration files ---"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cp "$SCRIPT_DIR/docker-compose.yml"              "$DEPLOY_DIR/"
cp "$SCRIPT_DIR/.env"                             "$DEPLOY_DIR/"
cp "$SCRIPT_DIR/postgres/postgresql.conf"         "$DEPLOY_DIR/postgres/"
cp "$SCRIPT_DIR/postgres/init/01-init-n8n.sql"    "$DEPLOY_DIR/postgres/init/"
cp "$SCRIPT_DIR/runners/Dockerfile"               "$DEPLOY_DIR/runners/"
cp "$SCRIPT_DIR/runners/n8n-task-runners.json"    "$DEPLOY_DIR/runners/"

chmod 600 "$DEPLOY_DIR/.env"
log "All config files copied"

# --- Step 4: Generate Secrets & Configure Socket ---
echo ""
echo "--- Step 4: Generating secrets ---"

DB_PASS=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
ENCRYPTION_KEY=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
RUNNER_TOKEN=$(openssl rand -base64 48 | tr -d '/+=' | head -c 48)

sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|"             "$DEPLOY_DIR/.env"
sed -i "s|^N8N_ENCRYPTION_KEY=.*|N8N_ENCRYPTION_KEY=${ENCRYPTION_KEY}|" "$DEPLOY_DIR/.env"
sed -i "s|^RUNNERS_AUTH_TOKEN=.*|RUNNERS_AUTH_TOKEN=${RUNNER_TOKEN}|"   "$DEPLOY_DIR/.env"
sed -i "s|^PODMAN_SOCKET=.*|PODMAN_SOCKET=${PODMAN_SOCKET}|"          "$DEPLOY_DIR/.env"

log "Secrets generated and socket path configured"
warn "IMPORTANT — Save these somewhere secure (e.g., AWS Secrets Manager):"
echo ""
echo "  DB_PASSWORD        = ${DB_PASS}"
echo "  N8N_ENCRYPTION_KEY = ${ENCRYPTION_KEY}"
echo "  RUNNERS_AUTH_TOKEN = ${RUNNER_TOKEN}"
echo "  PODMAN_SOCKET      = ${PODMAN_SOCKET}"
echo ""
warn "The encryption key is critical — losing it means losing access to all stored credentials in n8n."

# --- Step 5: Build and Launch ---
echo ""
echo "--- Step 5: Building and launching ---"
cd "$DEPLOY_DIR"

log "Building custom runners image..."
$COMPOSE build n8n-runners

log "Starting PostgreSQL first..."
$COMPOSE up -d postgres

echo "Waiting 15s for PostgreSQL to initialize..."
sleep 15

# Verify PG is ready
if podman exec n8n-postgres pg_isready -U n8n -d n8n &>/dev/null; then
    log "PostgreSQL is ready"
else
    warn "PostgreSQL may still be initializing. Continuing anyway (n8n will retry)..."
fi

log "Starting n8n..."
$COMPOSE up -d n8n

echo "Waiting 20s for n8n to start..."
sleep 20

log "Starting task runners and watchtower..."
$COMPOSE up -d n8n-runners watchtower

# --- Step 6: Verify ---
echo ""
echo "--- Step 6: Verifying deployment ---"
sleep 10

$COMPOSE ps
echo ""

log "Container health status:"
for svc in n8n-postgres n8n n8n-runners watchtower; do
    status=$(podman inspect --format='{{.State.Status}}' "$svc" 2>/dev/null || echo "not found")
    health=$(podman inspect --format='{{.State.Health.Status}}' "$svc" 2>/dev/null || echo "N/A")
    if [ "$status" = "running" ]; then
        echo -e "  ${GREEN}●${NC} $svc: status=$status health=$health"
    else
        echo -e "  ${RED}●${NC} $svc: status=$status health=$health"
    fi
done

# DB connectivity check
echo ""
if podman exec n8n-postgres psql -U n8n -d n8n -c "SELECT 1;" &>/dev/null; then
    log "PostgreSQL: database 'n8n' is accessible"
else
    warn "PostgreSQL may still be initializing. Check: $COMPOSE logs postgres"
fi

echo ""
echo "============================================="
log "Deployment complete!"
echo ""
echo "  Dashboard:     https://n8n.iitbacr.space"
echo "  Logs:          cd $DEPLOY_DIR && $COMPOSE logs -f"
echo "  Status:        cd $DEPLOY_DIR && $COMPOSE ps"
echo "  Resources:     podman stats --no-stream"
echo "  Stop:          cd $DEPLOY_DIR && $COMPOSE down"
echo ""
echo "  Update check:  $COMPOSE logs watchtower"
echo "  Manual update:"
echo "    $COMPOSE pull n8n"
echo "    $COMPOSE up -d n8n"
echo "============================================="
