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
    ["n8n-runners"]="n8n-runners"
)

# Reverse dependency map: containers that must be removed BEFORE the target
# can be removed (podman refuses to remove a container that has dependents).
# Order: leaf-first (n8n-runners before n8n) so removals succeed.
declare -A DEPENDENTS=(
    ["n8n-postgres"]="n8n-runners n8n"
    ["n8n-redis"]="n8n-runners n8n"
    ["n8n"]="n8n-runners"
    ["n8n-docling"]=""
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

# Strip "sha256:" prefix from image/container IDs for reliable comparison.
# Podman inconsistently includes/omits this prefix between container inspect
# ({{.Image}}) and image inspect ({{.Id}}), causing comparisons to fail.
normalize_id() { echo "${1#sha256:}"; }

# Stop and remove containers that depend on the target container.
# Podman tracks container dependencies (from depends_on in compose) and
# refuses to remove a container that has dependents. This function removes
# dependents leaf-first so the target can then be safely removed.
# Sets REMOVED_DEPS=() with the list of removed container names.
REMOVED_DEPS=()
remove_dependents() {
    local container="$1"
    REMOVED_DEPS=()
    local deps="${DEPENDENTS[$container]:-}"
    if [ -z "$deps" ]; then
        return
    fi
    for dep in $deps; do
        if podman container exists "$dep" 2>/dev/null; then
            print_info "Stopping dependent container $dep ..."
            podman stop "$dep" 2>/dev/null || true
            podman rm -f "$dep" 2>/dev/null || true
            REMOVED_DEPS+=("$dep")
        fi
    done
}

# Restart containers that were removed as dependents (root-first order).
restart_dependents() {
    if [ ${#REMOVED_DEPS[@]} -eq 0 ]; then
        return
    fi
    local i
    for (( i=${#REMOVED_DEPS[@]}-1; i>=0; i-- )); do
        local dep="${REMOVED_DEPS[$i]}"
        local dep_service="${CONTAINER_TO_SERVICE[$dep]:-}"
        if [ -n "$dep_service" ]; then
            print_info "Restarting dependent $dep ..."
            podman-compose up -d "$dep_service" || true
        fi
    done
}

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

    # Prefer skopeo (checks registry without pulling).
    # Falls back to podman pull if skopeo is unavailable.
    local use_skopeo=true
    if ! command -v skopeo &>/dev/null; then
        use_skopeo=false
        print_warning "skopeo not found — falling back to podman pull for update checks"
        print_warning "(install skopeo for faster, pull-free update detection)"
        echo ""
    fi

    for container in "${!CONTAINERS[@]}"; do
        image="${CONTAINERS[$container]}"
        name="${DISPLAY_NAMES[$container]}"

        # Get the image ID the running container was started from
        running_id=$(podman inspect --format '{{.Image}}' "$container" 2>/dev/null || echo "")
        running_id=$(normalize_id "$running_id")
        if [ -z "$running_id" ]; then
            print_skip "$name ($container) — not running, skipping"
            continue
        fi

        echo -en "  Checking ${BOLD}$name${NC} ... "

        if [ "$use_skopeo" = true ]; then
            # ---- skopeo path: compare digests without pulling ----
            #
            # NOTE: skopeo digest comparison can produce false positives
            # because containers-storage: and docker:// transports may
            # return different digest types (manifest-list vs platform-
            # specific manifest) for the same image.  When digests
            # differ, we pull the image and compare image IDs to verify
            # the update is genuine before reporting it.
            local_digest=$(skopeo inspect "containers-storage:$image" --format '{{.Digest}}' 2>/dev/null || echo "")
            remote_digest=$(skopeo inspect "docker://$image" --format '{{.Digest}}' 2>/dev/null || echo "")

            if [ -z "$remote_digest" ]; then
                echo ""
                print_error "$name — failed to query registry for $image"
                continue
            fi

            # If skopeo can't inspect local storage, fall back to podman digest
            if [ -z "$local_digest" ]; then
                local_digest=$(podman image inspect --format '{{.Digest}}' "$image" 2>/dev/null || echo "")
            fi

            if [ -n "$local_digest" ] && [ "$local_digest" = "$remote_digest" ]; then
                echo -e "${GREEN}up to date${NC}"
            else
                # Digests differ — verify by pulling and comparing image IDs.
                # This eliminates false positives from digest-type mismatches.
                if ! podman pull -q "$image" >/dev/null 2>&1; then
                    echo ""
                    print_error "$name — failed to pull $image for verification"
                    continue
                fi

                local latest_id
                latest_id=$(podman image inspect --format '{{.Id}}' "$image" 2>/dev/null || echo "")
                latest_id=$(normalize_id "$latest_id")

                if [ -n "$latest_id" ] && [ "$running_id" = "$latest_id" ]; then
                    echo -e "${GREEN}up to date${NC}"
                else
                    echo -e "${YELLOW}update available${NC}"
                    echo -e "         running: ${running_id:0:12}"
                    echo -e "         latest:  ${latest_id:0:12}"
                    UPDATABLE_CONTAINERS+=("$container")
                    UPDATABLE_IMAGES+=("$image")
                fi
            fi
        else
            # ---- fallback: pull quietly, then compare image IDs ----
            # NOTE: this pre-downloads the image, so the apply-phase pull
            # will show "already exists" for every layer.
            if ! podman pull -q "$image" >/dev/null 2>&1; then
                echo ""
                print_error "$name — failed to pull $image"
                continue
            fi

            latest_id=$(podman image inspect --format '{{.Id}}' "$image" 2>/dev/null || echo "")
            latest_id=$(normalize_id "$latest_id")

            if [ "$running_id" = "$latest_id" ]; then
                echo -e "${GREEN}up to date${NC}"
            else
                echo -e "${YELLOW}update available${NC}"
                echo -e "         running: ${running_id:0:12}"
                echo -e "         latest:  ${latest_id:0:12}"
                UPDATABLE_CONTAINERS+=("$container")
                UPDATABLE_IMAGES+=("$image")
            fi
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

    # Stop runners first so the base image is not in use
    print_info "Stopping n8n Runners ..."
    podman-compose stop n8n-runners || true

    # Force-remove container to ensure clean recreation
    print_info "Removing old container ..."
    podman rm -f n8n-runners 2>/dev/null || true

    # Remove old runners base image and the locally built image so the
    # rebuild starts completely fresh
    print_info "Removing old runners images ..."
    podman rmi "n8n-runners-python:latest" 2>/dev/null || true
    podman rmi "$RUNNERS_BASE_IMAGE" 2>/dev/null || true

    # Pull the latest runners base image
    print_info "Pulling latest runners base image ($RUNNERS_BASE_IMAGE) ..."
    if ! podman pull "$RUNNERS_BASE_IMAGE"; then
        print_error "Failed to pull $RUNNERS_BASE_IMAGE"
        return 2
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

        # Record the image ID the running container is currently using.
        # Only inspect the container (not the image tag) — the tag may
        # already point to a newer image from the check-phase pull.
        local old_image_id
        old_image_id=$(podman inspect --format '{{.Image}}' "$container" 2>/dev/null || echo "")
        old_image_id=$(normalize_id "$old_image_id")

        # Pull the latest image FIRST (container stays running — no downtime yet).
        # This lets us verify the image actually changed before stopping anything.
        print_info "Pulling latest image ($image) ..."
        if ! podman pull "$image"; then
            print_error "Failed to pull $image — retrying ..."
            if ! podman pull "$image"; then
                print_error "Failed to pull $image"
                ((failed++)) || true
                echo ""
                continue
            fi
        fi

        # Get the new image ID after pull (normalized for comparison)
        local new_image_id
        new_image_id=$(podman image inspect --format '{{.Id}}' "$image" 2>/dev/null || echo "")
        new_image_id=$(normalize_id "$new_image_id")

        # Podman tracks container dependencies (from depends_on) and refuses
        # to remove a container that has dependents. Remove dependents first.
        remove_dependents "$container"

        # Proceed with update — stop, clean up, and restart
        print_info "Stopping $name ..."
        if ! podman-compose stop "$service"; then
            print_error "Failed to stop $name"
            restart_dependents
            ((failed++)) || true
            echo ""
            continue
        fi

        # Force-remove container so podman-compose recreates it with the new image.
        print_info "Removing old container ..."
        podman rm -f "$container" 2>/dev/null || true

        # Remove the old image to free disk space (new image is already pulled)
        if [ -n "$old_image_id" ] && [ "$old_image_id" != "$new_image_id" ]; then
            print_info "Removing old image ..."
            podman rmi "$old_image_id" 2>/dev/null || true
        fi

        print_info "Starting $name with new image ..."
        if podman-compose up -d "$service"; then
            # Verify the new container is actually using the updated image
            local verify_id
            verify_id=$(normalize_id "$(podman inspect --format '{{.Image}}' "$container" 2>/dev/null || echo "")")

            if [ -n "$verify_id" ] && [ -n "$old_image_id" ] && [ "$verify_id" = "$old_image_id" ]; then
                print_error "$name — still running old image (${verify_id:0:12})"
                ((failed++)) || true
            else
                print_success "$name updated (image: ${old_image_id:0:12} → ${verify_id:0:12})"
                ((updated++)) || true
            fi
            # Track n8n update so we can offer runners rebuild
            if [ "$container" = "n8n" ]; then
                n8n_was_updated=true
            fi
        else
            print_error "Failed to start $name"
            ((failed++)) || true
        fi

        # Restart any dependents that were removed (skip n8n-runners if
        # n8n was updated — rebuild_runners will handle it separately).
        if [ "$container" = "n8n" ]; then
            # n8n-runners will be rebuilt below, don't restart with old image
            REMOVED_DEPS=()
        fi
        restart_dependents
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
