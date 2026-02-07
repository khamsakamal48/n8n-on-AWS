#!/usr/bin/env bash
# =============================================================================
# n8n Production — Fresh Deployment Script
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
echo " n8n Production — Fresh Deployment"
echo "============================================="
echo ""

# --- Pre-flight Checks ---
if command -v podman-compose &>/dev/null; then
    COMPOSE="podman-compose"
    RUNTIME="podman"
elif command -v docker-compose &>/dev/null; then
    COMPOSE="docker-compose"
    RUNTIME="docker"
elif command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
    COMPOSE="docker compose"
    RUNTIME="docker"
else
    err "No compose tool found. Install one:
    pip3 install podman-compose       # For Podman
    sudo apt install docker-compose   # For Docker"
fi
log "Using: $RUNTIME ($COMPOSE)"

# --- Step 1: Create Directory Structure ---
echo ""
echo "--- Step 1: Creating directory structure ---"
sudo mkdir -p "$DEPLOY_DIR"/{postgres/data,postgres/init,n8n/data,runners}
sudo chown -R "$(id -u):$(id -g)" "$DEPLOY_DIR"
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

chmod 600 "$DEPLOY_DIR/.env"
log "All config files copied"

# --- Step 3: Generate Secrets ---
echo ""
echo "--- Step 3: Generating secrets ---"

# Generate secure random values
DB_PASS=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
ENCRYPTION_KEY=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
RUNNER_TOKEN=$(openssl rand -base64 48 | tr -d '/+=' | head -c 48)

# Update .env with generated secrets
sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|" "$DEPLOY_DIR/.env"
sed -i "s|^N8N_ENCRYPTION_KEY=.*|N8N_ENCRYPTION_KEY=${ENCRYPTION_KEY}|" "$DEPLOY_DIR/.env"
sed -i "s|^RUNNERS_AUTH_TOKEN=.*|RUNNERS_AUTH_TOKEN=${RUNNER_TOKEN}|" "$DEPLOY_DIR/.env"

log "Secrets generated and written to .env"
warn "IMPORTANT: Save these somewhere secure (e.g., AWS Secrets Manager):"
echo ""
echo "  DB_PASSWORD       = ${DB_PASS}"
echo "  N8N_ENCRYPTION_KEY = ${ENCRYPTION_KEY}"
echo "  RUNNERS_AUTH_TOKEN = ${RUNNER_TOKEN}"
echo ""
warn "The encryption key is critical — losing it means losing access to all stored credentials in n8n."

# --- Step 4: Verify Podman Socket (for Watchtower) ---
echo ""
echo "--- Step 4: Verifying container runtime ---"

if [ "$RUNTIME" = "podman" ]; then
    # Watchtower needs the podman socket
    if [ ! -S "/run/podman/podman.sock" ]; then
        warn "Podman socket not found at /run/podman/podman.sock"
        echo "  Enable it with: sudo systemctl enable --now podman.socket"
        echo "  Or for rootless:  systemctl --user enable --now podman.socket"
        echo "  Then update docker-compose.yml volume path if using rootless."
    else
        log "Podman socket found"
    fi
fi

# --- Step 5: Build and Launch ---
echo ""
echo "--- Step 5: Building and launching ---"
cd "$DEPLOY_DIR"

log "Building custom runners image..."
$COMPOSE build n8n-runners

log "Starting all services..."
$COMPOSE up -d

# --- Step 6: Wait and Verify ---
echo ""
echo "--- Step 6: Verifying deployment ---"
echo "Waiting 20s for services to initialize..."
sleep 20

$COMPOSE ps
echo ""

log "Container health status:"
for svc in n8n-postgres n8n n8n-runners watchtower; do
    status=$($RUNTIME inspect --format='{{.State.Status}}' "$svc" 2>/dev/null || echo "not found")
    health=$($RUNTIME inspect --format='{{.State.Health.Status}}' "$svc" 2>/dev/null || echo "N/A")
    if [ "$status" = "running" ]; then
        echo -e "  ${GREEN}●${NC} $svc: status=$status health=$health"
    else
        echo -e "  ${RED}●${NC} $svc: status=$status health=$health"
    fi
done

# Quick DB connectivity check
echo ""
log "Checking PostgreSQL database..."
if $RUNTIME exec n8n-postgres psql -U n8n -d n8n -c "SELECT 1;" &>/dev/null; then
    log "PostgreSQL: database 'n8n' is accessible ✓"
else
    warn "PostgreSQL may still be initializing. Check: $COMPOSE logs postgres"
fi

echo ""
echo "============================================="
log "Deployment complete!"
echo ""
echo "  Dashboard:    https://n8n.iitbacr.space"
echo "  Logs:         cd $DEPLOY_DIR && $COMPOSE logs -f"
echo "  Status:       cd $DEPLOY_DIR && $COMPOSE ps"
echo "  Stop:         cd $DEPLOY_DIR && $COMPOSE down"
echo ""
echo "  Update check: $COMPOSE logs watchtower"
echo ""
echo "  Manual update workflow:"
echo "    $COMPOSE pull n8n"
echo "    $COMPOSE up -d n8n"
echo "============================================="
