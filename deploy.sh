#!/usr/bin/env bash
# =============================================================================
# n8n Production — Fresh Deployment Script (Podman-native)
# Target: AWS EC2 t3.xlarge (4 vCPU, 16 GB RAM)
# =============================================================================
set -euo pipefail

DEPLOY_DIR="/opt/n8n-production"
export COMPOSE_PROJECT_NAME="n8n-automation"

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

# --- Step 1: Create Directory Structure ---
echo ""
echo "--- Step 1: Creating directory structure ---"
sudo mkdir -p "$DEPLOY_DIR"/{postgres/data,postgres/init,n8n/data,runners,redis/data,docling/{hf-cache,models,documents}}
sudo chown -R "$(id -u):$(id -g)" "$DEPLOY_DIR"
# n8n container runs as user "node" (UID 1000). The data directory must be
# writable by this UID, otherwise n8n fails with EACCES on /home/node/.n8n/config.
sudo chown -R 1000:1000 "$DEPLOY_DIR/n8n/data"
# Docling container runs as user "default" (UID 1001). Cache directories must
# be writable by this UID, otherwise model downloads fail with Permission denied.
sudo chown -R 1001:0 "$DEPLOY_DIR/docling/hf-cache" "$DEPLOY_DIR/docling/models"
log "Created $DEPLOY_DIR"

# --- Step 2: Copy Configuration Files ---
echo ""
echo "--- Step 2: Copying configuration files ---"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cp "$SCRIPT_DIR/docker-compose.yml"              "$DEPLOY_DIR/"
cp "$SCRIPT_DIR/.env"                             "$DEPLOY_DIR/"
cp "$SCRIPT_DIR/postgres/postgresql.conf"         "$DEPLOY_DIR/postgres/"
cp "$SCRIPT_DIR/postgres/init/01-init-n8n.sql"    "$DEPLOY_DIR/postgres/init/"
cp "$SCRIPT_DIR/runners/Dockerfile"               "$DEPLOY_DIR/runners/"
cp "$SCRIPT_DIR/runners/n8n-task-runners.json"    "$DEPLOY_DIR/runners/"
cp "$SCRIPT_DIR/redis/redis.conf"                 "$DEPLOY_DIR/redis/"
cp "$SCRIPT_DIR/docling/download-models.sh"       "$DEPLOY_DIR/docling/"
cp "$SCRIPT_DIR/check-updates.sh"                 "$DEPLOY_DIR/"

chmod 600 "$DEPLOY_DIR/.env"
chmod +x "$DEPLOY_DIR/docling/download-models.sh"
chmod +x "$DEPLOY_DIR/check-updates.sh"
log "All config files copied"

# --- Step 3: Generate Secrets ---
echo ""
echo "--- Step 3: Generating secrets ---"

DB_PASS=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
ENCRYPTION_KEY=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
RUNNER_TOKEN=$(openssl rand -base64 48 | tr -d '/+=' | head -c 48)
REDIS_PASS=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)

sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|"             "$DEPLOY_DIR/.env"
sed -i "s|^N8N_ENCRYPTION_KEY=.*|N8N_ENCRYPTION_KEY=${ENCRYPTION_KEY}|" "$DEPLOY_DIR/.env"
sed -i "s|^RUNNERS_AUTH_TOKEN=.*|RUNNERS_AUTH_TOKEN=${RUNNER_TOKEN}|"   "$DEPLOY_DIR/.env"
sed -i "s|^REDIS_PASSWORD=.*|REDIS_PASSWORD=${REDIS_PASS}|"           "$DEPLOY_DIR/.env"

log "Secrets generated"
warn "IMPORTANT — Save these somewhere secure (e.g., AWS Secrets Manager):"
echo ""
echo "  DB_PASSWORD        = ${DB_PASS}"
echo "  N8N_ENCRYPTION_KEY = ${ENCRYPTION_KEY}"
echo "  RUNNERS_AUTH_TOKEN = ${RUNNER_TOKEN}"
echo "  REDIS_PASSWORD     = ${REDIS_PASS}"
echo ""
warn "The encryption key is critical — losing it means losing access to all stored credentials in n8n."

# --- Step 4: Install Systemd Services ---
echo ""
echo "--- Step 4: Installing systemd services ---"

log "Installing n8n-stack auto-start service..."
# Substitute the current user and group into the service file
# This ensures the service runs as the same user who deployed the containers
CURRENT_USER="$(id -un)"
CURRENT_GROUP="$(id -gn)"
sed "s/__DEPLOY_USER__/${CURRENT_USER}/g; s/__DEPLOY_GROUP__/${CURRENT_GROUP}/g" \
    "$SCRIPT_DIR/systemd/n8n-stack.service" | sudo tee /etc/systemd/system/n8n-stack.service >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable n8n-stack.service

log "Installing daily image update-check timer..."
sudo cp "$SCRIPT_DIR/systemd/n8n-check-updates.service" /etc/systemd/system/
sudo cp "$SCRIPT_DIR/systemd/n8n-check-updates.timer"   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now n8n-check-updates.timer

log "Systemd services installed successfully"
echo "  Auto-start:    n8n-stack.service (enabled, will start on next boot)"
echo "  Update check:  n8n-check-updates.timer (enabled, runs daily)"
echo "  View results:  journalctl -u n8n-check-updates.service --since today"
echo "  Run check now: sudo systemctl start n8n-check-updates.service"

# --- Step 5: Build and Launch ---
echo ""
echo "--- Step 5: Building and launching ---"
cd "$DEPLOY_DIR"

log "Building custom runners image..."
$COMPOSE build n8n-runners

log "Starting PostgreSQL and Redis first..."
$COMPOSE up -d postgres redis

echo "Waiting 15s for PostgreSQL and Redis to initialize..."
sleep 15

# Verify PG is ready
if podman exec n8n-postgres pg_isready -U n8n -d n8n &>/dev/null; then
    log "PostgreSQL is ready"
else
    warn "PostgreSQL may still be initializing. Continuing anyway (n8n will retry)..."
fi

# Verify Redis is ready
if podman exec n8n-redis redis-cli -a "$REDIS_PASS" ping 2>/dev/null | grep -q "PONG"; then
    log "Redis is ready"
else
    warn "Redis may still be initializing. Continuing anyway..."
fi

log "Starting n8n..."
$COMPOSE up -d n8n

echo "Waiting 20s for n8n to start..."
sleep 20

log "Starting task runners and Docling Serve..."
$COMPOSE up -d n8n-runners docling

# --- Step 6: Verify ---
echo ""
echo "--- Step 6: Verifying deployment ---"
sleep 10

$COMPOSE ps
echo ""

log "Container health status:"
for svc in n8n-postgres n8n-redis n8n n8n-runners n8n-docling; do
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

# Redis connectivity check
if podman exec n8n-redis redis-cli -a "$REDIS_PASS" ping 2>/dev/null | grep -q "PONG"; then
    log "Redis: PONG response received"
else
    warn "Redis may still be initializing. Check: $COMPOSE logs redis"
fi

echo ""
echo "============================================="
log "Deployment complete!"
echo ""
echo "  Dashboard:     https://n8n.iitbacr.space"
echo "  Docling UI:    http://localhost:5001/ui"
echo "  Docling Docs:  http://localhost:5001/docs"
echo ""
echo "  Auto-start:    Enabled (containers will start automatically on boot)"
echo "  Service:       sudo systemctl status n8n-stack.service"
echo ""
echo "  Logs:          cd $DEPLOY_DIR && $COMPOSE logs -f"
echo "  Status:        cd $DEPLOY_DIR && $COMPOSE ps"
echo "  Resources:     podman stats --no-stream"
echo "  Stop:          sudo systemctl stop n8n-stack.service"
echo "  Start:         sudo systemctl start n8n-stack.service"
echo ""
echo "  Update check:  journalctl -u n8n-check-updates.service --since today"
echo "  Run check now: sudo systemctl start n8n-check-updates.service"
echo "  Manual update:"
echo "    $COMPOSE pull n8n"
echo "    $COMPOSE up -d n8n"
echo ""
echo "  Redis Chat Memory — configure in n8n UI:"
echo "    Host: n8n-redis   Port: 6379   Password: (in .env)"
echo ""
echo "  ⚠ Download Docling models (recommended — avoids cold-start delays):"
echo "    Wait ~2 min for Docling to finish booting, then run:"
echo "    cd $DEPLOY_DIR && ./docling/download-models.sh"
echo "============================================="
