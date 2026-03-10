#!/usr/bin/env bash
# =============================================================================
# check-updates.sh — Check for container image updates (Podman-native)
# =============================================================================
# Replaces Watchtower (monitor-only mode) with a simple Podman-native script.
# Runs daily via systemd timer (n8n-check-updates.timer).
#
# How it works:
#   1. For each monitored container, get the local image digest
#   2. Query the registry for the remote digest (via skopeo, no pull)
#   3. Compare local vs remote digests to detect updates
#   4. Log results to stdout (captured by systemd journal)
#
# Falls back to podman pull if skopeo is not installed, but this has the
# side effect of downloading the new image during the check itself.
#
# Locally-built images (n8n-runners) are skipped — they have no remote tag.
#
# View results:
#   journalctl -u n8n-check-updates.service --since today
# =============================================================================
set -euo pipefail

COMPOSE_DIR="/opt/n8n-production"

# Container name → remote image mapping
# Excludes n8n-runners (locally built, no remote tag to check)
declare -A CONTAINERS=(
    ["n8n-postgres"]="docker.io/library/postgres:latest"
    ["n8n-redis"]="docker.io/library/redis:latest"
    ["n8n"]="docker.n8n.io/n8nio/n8n:stable"
    ["n8n-docling"]="quay.io/docling-project/docling-serve-cpu:latest"
)

UPDATES=()
ERRORS=()

# Prefer skopeo (checks registry without pulling)
USE_SKOPEO=true
if ! command -v skopeo &>/dev/null; then
    USE_SKOPEO=false
fi

echo "=== n8n Stack — Image Update Check ($(date --iso-8601=minutes)) ==="
if [ "$USE_SKOPEO" = false ]; then
    echo "  (skopeo not found — using podman pull fallback)"
fi
echo ""

for container in "${!CONTAINERS[@]}"; do
    image="${CONTAINERS[$container]}"

    # Get the image ID the running container was started from
    running_id=$(podman inspect --format '{{.Image}}' "$container" 2>/dev/null || echo "")
    if [ -z "$running_id" ]; then
        echo "  SKIP  $container — not running"
        continue
    fi

    if [ "$USE_SKOPEO" = true ]; then
        # ---- skopeo path: compare digests without pulling ----
        local_digest=$(podman image inspect --format '{{.Digest}}' "$image" 2>/dev/null || echo "")
        remote_digest=$(skopeo inspect "docker://$image" --format '{{.Digest}}' 2>/dev/null || echo "")

        if [ -z "$remote_digest" ]; then
            echo "  ERROR $container — failed to query registry for $image"
            ERRORS+=("$container")
            continue
        fi

        if [ "$local_digest" = "$remote_digest" ]; then
            echo "  OK    $container — up to date"
        else
            echo "  NEW   $container — update available"
            echo "          image:   $image"
            echo "          local:   ${local_digest:7:12}"
            echo "          remote:  ${remote_digest:7:12}"
            UPDATES+=("$container")
        fi
    else
        # ---- fallback: pull quietly, then compare image IDs ----
        if ! podman pull -q "$image" >/dev/null 2>&1; then
            echo "  ERROR $container — failed to pull $image"
            ERRORS+=("$container")
            continue
        fi

        latest_id=$(podman image inspect --format '{{.Id}}' "$image" 2>/dev/null || echo "")

        if [ "$running_id" = "$latest_id" ]; then
            echo "  OK    $container — up to date"
        else
            echo "  NEW   $container — update available"
            echo "          image:   $image"
            echo "          running: ${running_id:0:12}"
            echo "          latest:  ${latest_id:0:12}"
            UPDATES+=("$container")
        fi
    fi
done

echo ""

if [ ${#ERRORS[@]} -gt 0 ]; then
    echo "Errors pulling: ${ERRORS[*]}"
fi

if [ ${#UPDATES[@]} -gt 0 ]; then
    echo "Updates available for: ${UPDATES[*]}"
    echo ""
    echo "To apply updates:"
    echo "  cd $COMPOSE_DIR"
    for svc in "${UPDATES[@]}"; do
        echo "  podman-compose up -d ${svc/#n8n-/}"
    done
else
    echo "All monitored containers are up to date."
fi
