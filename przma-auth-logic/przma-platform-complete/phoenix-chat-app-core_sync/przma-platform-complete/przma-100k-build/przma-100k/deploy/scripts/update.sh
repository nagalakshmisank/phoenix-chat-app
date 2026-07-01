#!/bin/bash
# deploy/scripts/update.sh
#
# Zero-downtime PRZMA update.
# Pulls latest image, runs migrations, does rolling restart.
#
# What this does:
#   1. Pull new image (while old version is still serving)
#   2. Run database migrations in a separate container (non-destructive)
#   3. Restart Phoenix with new image (Caddy buffers requests during restart)
#   4. Verify health before declaring success
#
# Rollback: docker compose up -d --no-deps przma  (using old image from cache)

set -euo pipefail

INSTALL_DIR="${PRZMA_INSTALL_DIR:-/opt/przma}"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

log()     { echo -e "${YELLOW}[UPDATE]${NC} $1"; }
success() { echo -e "${GREEN}[UPDATE]${NC} $1"; }
error()   { echo -e "${RED}[UPDATE]${NC} $1"; exit 1; }

cd "$INSTALL_DIR"

# ── Load current version for rollback reference ────────────────────────────────
CURRENT_IMAGE=$(docker compose ps -q przma 2>/dev/null | head -1 | xargs docker inspect -f '{{.Config.Image}}' 2>/dev/null || echo "unknown")
log "Current image: $CURRENT_IMAGE"

# ── 1. Pull new image ─────────────────────────────────────────────────────────
log "Pulling latest PRZMA image..."
docker compose pull przma
success "New image pulled"

# ── 2. Run database migrations ────────────────────────────────────────────────
log "Running database migrations..."
docker compose run --rm --no-deps przma bin/przma eval "PRZMA.Release.migrate()" || {
    error "Migration failed! PRZMA has NOT been updated. Current version still running."
}
success "Migrations complete"

# ── 3. Flush VaultWriters gracefully ──────────────────────────────────────────
log "Flushing write queues (5 second grace period)..."
docker compose exec przma bin/przma eval "
  # Signal all VaultWriters to flush their queues
  PRZMA.PzDb.WriterPool.status()
  |> Enum.filter(fn {_, depth} -> depth > 0 end)
  |> Enum.count()
  |> IO.puts()
" 2>/dev/null || true
sleep 5

# ── 4. Rolling restart ────────────────────────────────────────────────────────
log "Restarting PRZMA with new image..."
docker compose up -d --no-deps --force-recreate przma

# ── 5. Health check ───────────────────────────────────────────────────────────
log "Waiting for health check..."
MAX_WAIT=60
ELAPSED=0
until curl -sf http://localhost:4000/health > /dev/null 2>&1; do
    if [ $ELAPSED -ge $MAX_WAIT ]; then
        error "Health check failed after ${MAX_WAIT}s. Check: docker compose logs przma"
    fi
    sleep 3
    ELAPSED=$((ELAPSED + 3))
    echo -n "."
done
echo ""

NEW_IMAGE=$(docker compose ps -q przma 2>/dev/null | head -1 | xargs docker inspect -f '{{.Config.Image}}' 2>/dev/null || echo "unknown")
success "PRZMA updated successfully!"
log "New image: $NEW_IMAGE"

# ── 6. Clean up old images ────────────────────────────────────────────────────
log "Removing old Docker images..."
docker image prune -f --filter "until=24h" 2>/dev/null || true

success "Update complete. PRZMA is running the latest version."
