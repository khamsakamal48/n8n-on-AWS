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
# When n8n has an update, the n8n-runners base image (n8nio/runners:stable)
# is also updated. The script detects this and offers to rebuild + restart
# the runners automatically.
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
# Excludes n8n-runners (locally built — rebuilt when n8n is updated).
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

# Runners base image (FROM line in runners/Dockerfile)
RUNNERS_BASE_IMAGE="docker.io/n8nio/runners:stable"

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

# --- Rebuild n8n Runners ---------------------------------------------------
# Called automatically when n8n is updated, since the runners base image
# (n8nio/runners:stable) tracks the same release cycle.
rebuild_runners() {
    echo -e "────────────────────────────────────────────────────"
    echo -e "  ${BOLD}n8n Runners${NC}  (service: n8n-runners)"
    echo -e "  Base image: $RUNNERS_BASE_IMAGE"
    echo -e "  ${YELLOW}n8n was updated — runners base image has a matching update${NC}"
    echo ""

    if ! ask_yes_no "  Rebuild and update n8n Runners?"; then
        print_skip "Skipped n8n Runners"
        return 1
    fi

    echo ""

    # Pull the latest runners base image so the build uses it
    print_info "Pulling latest runners base image ($RUNNERS_BASE_IMAGE) ..."
    if ! podman pull "$RUNNERS_BASE_IMAGE" -q >/dev/null 2>&1; then
        print_error "Failed to pull $RUNNERS_BASE_IMAGE"
        return 2
    fi

    # Stop runners
    print_info "Stopping n8n Runners ..."
    podman-compose stop n8n-runners || true

    # Clean up stopped container
    local state
    state=$(podman ps -a --filter "name=^n8n-runners$" --format "{{.State}}" 2>/dev/null || echo "")
    if [[ "$state" == "exited" || "$state" == "stopped" ]]; then
        print_info "Removing stopped container ..."
        podman rm n8n-runners 2>/dev/null || true
    fi

    # Rebuild with --no-cache to ensure the new base image is used
    print_info "Rebuilding n8n Runners image (--no-cache) ..."
    if ! podman-compose build --no-cache n8n-runners; then
        print_error "Failed to rebuild n8n Runners image"
        return 2
    fi

    # Start runners
    print_info "Starting n8n Runners with new image ..."
    if podman-compose up -d n8n-runners; then
        print_success "n8n Runners rebuilt and updated successfully"
        return 0
    else
        print_error "Failed to start n8n Runners"
        return 2
    fi
}

# --- Phase 2: Interactive update -------------------------------------------
apply_updates() {
    if [ ${#UPDATABLE_CONTAINERS[@]} -eq 0 ]; then
        print_success "All monitored containers are up to date. Nothing to do."
        echo ""
        return
    fi

    local n8n_in_list=false
    for i in "${!UPDATABLE_CONTAINERS[@]}"; do
        if [ "${UPDATABLE_CONTAINERS[$i]}" = "n8n" ]; then
            n8n_in_list=true
            break
        fi
    done

    local extra=0
    if [ "$n8n_in_list" = true ]; then
        extra=1
    fi

    echo -e "${BOLD}Updates available for $(( ${#UPDATABLE_CONTAINERS[@]} + extra )) container(s):${NC}"
    for i in "${!UPDATABLE_CONTAINERS[@]}"; do
        local container="${UPDATABLE_CONTAINERS[$i]}"
        local name="${DISPLAY_NAMES[$container]}"
        echo -e "  ${YELLOW}•${NC} $name ($container)"
    done
    if [ "$n8n_in_list" = true ]; then
        echo -e "  ${YELLOW}•${NC} n8n Runners (n8n-runners) — rebuild needed, base image tracks n8n"
    fi
    echo ""

    # Move into compose directory for podman-compose commands
    cd "$COMPOSE_DIR"

    local updated=0
    local skipped=0
    local failed=0
    local n8n_was_updated=false

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
            ((skipped++)) || true
            echo ""
            continue
        fi

        echo ""
        print_info "Stopping $name ..."
        if ! podman-compose stop "$service"; then
            print_error "Failed to stop $name"
            ((failed++)) || true
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
            ((updated++)) || true
            # Track n8n update so we can offer runners rebuild
            if [ "$container" = "n8n" ]; then
                n8n_was_updated=true
            fi
        else
            print_error "Failed to start $name"
            ((failed++)) || true
        fi
        echo ""
    done

    # If n8n was updated, offer to rebuild runners (same release cycle)
    if [ "$n8n_was_updated" = true ]; then
        rebuild_runners
        local rc=$?
        if [ $rc -eq 0 ]; then
            ((updated++)) || true
        elif [ $rc -eq 1 ]; then
            ((skipped++)) || true
        else
            ((failed++)) || true
        fi
        echo ""
    fi

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
