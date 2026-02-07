#!/usr/bin/env bash
# =============================================================================
# Pre-download Docling models into persistent cache
# =============================================================================
# Run this AFTER deploy.sh has started the Docling container at least once.
# Downloads all recommended models for CPU-only operation into the persistent
# volume so they survive container restarts/upgrades.
#
# Models downloaded:
#   1. Default pipeline models (layout, tableformer, OCR, picture classifier)
#   2. SmolDocling-256M       — VLM for full-page document → DocTags conversion
#   3. Granite-Docling-258M   — IBM's VLM for document understanding
#   4. SmolVLM-256M-Instruct  — picture description (smallest, CPU-friendly)
#
# All models run on CPU. No GPU required.
# Total download size: ~3-5 GB (one-time download)
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

CONTAINER="n8n-docling"

# Check container is running
if ! podman inspect "$CONTAINER" &>/dev/null; then
    err "Container '$CONTAINER' not found. Start the stack first: podman-compose up -d docling"
fi

STATUS=$(podman inspect --format='{{.State.Status}}' "$CONTAINER" 2>/dev/null)
if [ "$STATUS" != "running" ]; then
    err "Container '$CONTAINER' is not running (status: $STATUS)"
fi

echo "============================================="
echo " Docling Model Download — CPU-only models"
echo "============================================="
echo ""

# --- Step 0: Fix cache directory permissions ---
# The container runs as user "default" (UID 1001). Mounted host volumes
# may be owned by root or the deploy user, causing "Permission denied"
# when HuggingFace tries to create subdirectories (hub/, xet/logs/, etc.).
log "Ensuring cache directories are writable by container user..."
podman exec --user 0 "$CONTAINER" sh -c '
    mkdir -p /home/default/.cache/huggingface/hub \
             /home/default/.cache/huggingface/xet/logs \
             /home/default/.cache/docling/models
    chown -R $(id -u default):0 /home/default/.cache/huggingface \
                                /home/default/.cache/docling
' || warn "Could not fix cache directory permissions — downloads may fail"

# --- Step 1: Download default pipeline models ---
log "Downloading default pipeline models (layout, tableformer, OCR, etc.)..."
podman exec "$CONTAINER" docling-tools models download || {
    warn "docling-tools models download failed — models may download at first request instead"
}

# --- Step 2: Download SmolDocling-256M (VLM — full page → DocTags) ---
log "Downloading SmolDocling-256M (VLM document conversion)..."
podman exec "$CONTAINER" docling-tools models download-hf-repo \
    docling-project/SmolDocling-256M-preview 2>/dev/null || \
podman exec "$CONTAINER" python -c "
from huggingface_hub import snapshot_download
snapshot_download('docling-project/SmolDocling-256M-preview')
print('SmolDocling-256M downloaded successfully')
" || warn "SmolDocling-256M download failed — will download on first use"

# --- Step 3: Download Granite-Docling-258M (IBM's VLM for documents) ---
log "Downloading Granite-Docling-258M (IBM document VLM)..."
podman exec "$CONTAINER" docling-tools models download-hf-repo \
    ibm-granite/granite-docling-258M 2>/dev/null || \
podman exec "$CONTAINER" python -c "
from huggingface_hub import snapshot_download
snapshot_download('ibm-granite/granite-docling-258M')
print('Granite-Docling-258M downloaded successfully')
" || warn "Granite-Docling-258M download failed — will download on first use"

# --- Step 4: Download SmolVLM-256M-Instruct (picture description) ---
log "Downloading SmolVLM-256M-Instruct (picture description)..."
podman exec "$CONTAINER" docling-tools models download-hf-repo \
    HuggingFaceTB/SmolVLM-256M-Instruct 2>/dev/null || \
podman exec "$CONTAINER" python -c "
from huggingface_hub import snapshot_download
snapshot_download('HuggingFaceTB/SmolVLM-256M-Instruct')
print('SmolVLM-256M-Instruct downloaded successfully')
" || warn "SmolVLM-256M-Instruct download failed — will download on first use"

echo ""
echo "============================================="
log "Model download complete!"
echo ""
echo "  Models are cached in ./docling/hf-cache and ./docling/models"
echo "  They persist across container restarts and upgrades."
echo ""
echo "  To verify, check the container's model cache:"
echo "    podman exec $CONTAINER ls -la /home/default/.cache/docling/models/"
echo "    podman exec $CONTAINER ls -la /home/default/.cache/huggingface/hub/"
echo ""
echo "  Test with:"
echo "    curl -X POST http://localhost:5001/v1/convert/source \\"
echo "      -H 'Content-Type: application/json' \\"
echo "      -d '{\"sources\": [{\"kind\": \"http\", \"url\": \"https://arxiv.org/pdf/2501.17887\"}]}'"
echo "============================================="
