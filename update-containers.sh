#!/usr/bin/env bash
# =============================================================================
# update-containers.sh — Interactive container updater for n8n stack
# =============================================================================
# Checks for image updates (reusing the check-updates logic), then for each
# container with an available update, asks whether you want to apply it.
#
# For each "yes": safely stops the container, pulls the latest image, and
# restarts it via podman-compose.
#
# Usage:
#   ./update-containers.sh            # Run from /opt/n8n-production
#   ./update-containers.sh --check    # Check only, don't offer to update
#
# Locally-built images (n8n-runners) are skipped — no remote tag to check.
# =============================================================================
set -euo pipefail

COMPOSE_DIR="/opt/n8n-production"

# --- Colors ---------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# --- Container → image mapping --------------------------------------------
# Same mapping as check-updates.sh. Excludes n8n-runners (locally built).
declare -A CONTAINERS=(
    ["n8n-postgres"]="docker.io/library/postgres:latest"
    ["n8n-redis"]="docker.io/library/redis:latest"
    ["n8n"]="docker.n8n.io/n8nio/n8n:stable"
    ["n8n-docling"]="quay.io/docling-project/docling-serve-cpu:latest"
)

# Container name → compose service name
declare -A CONTAINER_TO_SERVICE=(
    ["n8n-postgres"]="postgres"
    ["n8n-redis"]="redis"
    ["n8n"]="n8n"
    ["n8n-docling"]="docling"
)

# Friendly display names
declare -A DISPLAY_NAMES=(
    ["n8n-postgres"]="PostgreSQL"
    ["n8n-redis"]="Redis"
    ["n8n"]="n8n"
    ["n8n-docling"]="Docling Serve"
)

# --- Helpers ---------------------------------------------------------------
print_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC}   $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error()   { echo -e "${RED}[ERR]${NC}  $1"; }
print_skip()    { echo -e "       $1"; }

# Ask a yes/no question. Returns 0 for yes, 1 for no.
ask_yes_no() {
    local prompt="$1"
    while true; do
        echo -en "${BOLD}${prompt} [y/n]: ${NC}"
        read -r answer
        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     echo "  Please answer y or n." ;;
        esac
    done
}

# --- Prerequisites ---------------------------------------------------------
check_prerequisites() {
    if ! command -v podman &>/dev/null; then
        print_error "podman is not installed or not in PATH"
        exit 1
    fi
    if ! command -v podman-compose &>/dev/null; then
        print_error "podman-compose is not installed or not in PATH"
        exit 1
    fi
    if [ ! -f "$COMPOSE_DIR/docker-compose.yml" ]; then
        print_error "docker-compose.yml not found in $COMPOSE_DIR"
        exit 1
    fi
}

# --- Phase 1: Check for updates -------------------------------------------
check_for_updates() {
    echo ""
    echo -e "${BOLD}=== n8n Stack — Checking for container updates ===${NC}"
    echo -e "    $(date '+%Y-%m-%d %H:%M %Z')"
    echo ""

    UPDATABLE_CONTAINERS=()
    UPDATABLE_IMAGES=()
    UPDATABLE_RUNNING_IDS=()
    UPDATABLE_LATEST_IDS=()

    for container in "${!CONTAINERS[@]}"; do
        image="${CONTAINERS[$container]}"
        name="${DISPLAY_NAMES[$container]}"

        # Get the image ID the running container was started from
        running_id=$(podman inspect --format '{{.Image}}' "$container" 2>/dev/null || echo "")
        if [ -z "$running_id" ]; then
            print_skip "$name ($container) — not running, skipping"
            continue
        fi

        echo -en "  Checking ${BOLD}$name${NC} ... "

        # Pull latest tag (only downloads changed layers)
        if ! podman pull "$image" -q >/dev/null 2>&1; then
            echo ""
            print_error "$name — failed to pull $image"
            continue
        fi

        # Compare image IDs
        latest_id=$(podman image inspect --format '{{.Id}}' "$image" 2>/dev/null || echo "")

        if [ "$running_id" = "$latest_id" ]; then
            echo -e "${GREEN}up to date${NC}"
        else
            echo -e "${YELLOW}update available${NC}"
            echo -e "         running: ${running_id:0:12}"
            echo -e "         latest:  ${latest_id:0:12}"
            UPDATABLE_CONTAINERS+=("$container")
            UPDATABLE_IMAGES+=("$image")
            UPDATABLE_RUNNING_IDS+=("$running_id")
            UPDATABLE_LATEST_IDS+=("$latest_id")
        fi
    done

    echo ""
}

# --- Phase 2: Interactive update -------------------------------------------
apply_updates() {
    if [ ${#UPDATABLE_CONTAINERS[@]} -eq 0 ]; then
        print_success "All monitored containers are up to date. Nothing to do."
        echo ""
        return
    fi

    echo -e "${BOLD}Updates available for ${#UPDATABLE_CONTAINERS[@]} container(s):${NC}"
    for i in "${!UPDATABLE_CONTAINERS[@]}"; do
        local container="${UPDATABLE_CONTAINERS[$i]}"
        local name="${DISPLAY_NAMES[$container]}"
        echo -e "  ${YELLOW}•${NC} $name ($container)"
    done
    echo ""

    # Move into compose directory for podman-compose commands
    cd "$COMPOSE_DIR"

    local updated=0
    local skipped=0
    local failed=0

    for i in "${!UPDATABLE_CONTAINERS[@]}"; do
        local container="${UPDATABLE_CONTAINERS[$i]}"
        local image="${UPDATABLE_IMAGES[$i]}"
        local service="${CONTAINER_TO_SERVICE[$container]}"
        local name="${DISPLAY_NAMES[$container]}"

        echo -e "────────────────────────────────────────────────────"
        echo -e "  ${BOLD}$name${NC}  (service: $service)"
        echo -e "  Image: $image"
        echo ""

        if ! ask_yes_no "  Update $name?"; then
            print_skip "Skipped $name"
            ((skipped++))
            echo ""
            continue
        fi

        echo ""
        print_info "Stopping $name ..."
        if ! podman-compose stop "$service"; then
            print_error "Failed to stop $name"
            ((failed++))
            echo ""
            continue
        fi

        # Clean up stopped container to prevent name conflicts on restart
        local state
        state=$(podman ps -a --filter "name=^${container}$" --format "{{.State}}" 2>/dev/null || echo "")
        if [[ "$state" == "exited" || "$state" == "stopped" ]]; then
            print_info "Removing stopped container ..."
            podman rm "$container" 2>/dev/null || true
        fi

        print_info "Starting $name with new image ..."
        if podman-compose up -d "$service"; then
            print_success "$name updated successfully"
            ((updated++))
        else
            print_error "Failed to start $name"
            ((failed++))
        fi
        echo ""
    done

    # --- Summary -----------------------------------------------------------
    echo -e "════════════════════════════════════════════════════"
    echo -e "${BOLD}  Summary${NC}"
    echo -e "════════════════════════════════════════════════════"
    [ $updated -gt 0 ] && echo -e "  ${GREEN}Updated:${NC}  $updated"
    [ $skipped -gt 0 ] && echo -e "  ${YELLOW}Skipped:${NC}  $skipped"
    [ $failed  -gt 0 ] && echo -e "  ${RED}Failed:${NC}   $failed"
    echo ""

    if [ $updated -gt 0 ]; then
        print_info "Current container status:"
        echo ""
        podman ps -a --filter "name=n8n" --format "table {{.Names}}\t{{.State}}\t{{.Status}}\t{{.Image}}"
        echo ""
    fi
}

# --- Main ------------------------------------------------------------------
main() {
    check_prerequisites

    check_for_updates

    # --check flag: only show results, don't offer to update
    if [[ "${1:-}" == "--check" ]]; then
        if [ ${#UPDATABLE_CONTAINERS[@]} -gt 0 ]; then
            echo "Run without --check to apply updates interactively."
            echo ""
        fi
        return
    fi

    apply_updates
}

main "$@"
