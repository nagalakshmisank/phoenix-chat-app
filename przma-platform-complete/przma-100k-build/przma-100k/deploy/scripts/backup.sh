#!/bin/bash
# deploy/scripts/backup.sh
#
# PRZMA daily backup — vaults + PostgreSQL.
# Run manually or via cron (installed by install.sh at 03:00 daily).
#
# What is backed up:
#   - Lance vault files (MinIO data volume) — the critical user data
#   - PostgreSQL dump (Oban job state — less critical, small)
#
# Where backups go:
#   - Local: /var/lib/przma/backups/ (kept for 7 days)
#   - Remote: Optional rclone sync to any S3/cloud (configure BACKUP_REMOTE)
#
# Storage estimate: ~50MB per 100 active users per day (Lance + PG dump)

set -euo pipefail

INSTALL_DIR="${PRZMA_INSTALL_DIR:-/opt/przma}"
BACKUP_DIR="${PRZMA_BACKUP_DIR:-/var/lib/przma/backups}"
KEEP_DAYS=7
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/przma_backup_$DATE"

# Optional: remote backup destination (any rclone remote)
# BACKUP_REMOTE="s3:my-przma-backups/"  # Uncomment and configure

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

log "Starting PRZMA backup..."
mkdir -p "$BACKUP_DIR"

# ── 1. Backup Lance vault files (via MinIO volume) ────────────────────────────
log "Backing up vault data (Lance files)..."
if docker volume inspect przma_minio_data &>/dev/null; then
    docker run --rm \
        -v przma_minio_data:/data:ro \
        -v "$BACKUP_DIR":/backup \
        alpine:latest \
        tar czf "/backup/vaults_$DATE.tar.gz" -C /data .
    log "Vault backup: $BACKUP_DIR/vaults_$DATE.tar.gz ($(du -h "$BACKUP_DIR/vaults_$DATE.tar.gz" | cut -f1))"
else
    log "Warning: MinIO volume not found — skipping vault backup"
fi

# ── 2. Backup PostgreSQL (Oban job state) ─────────────────────────────────────
log "Backing up PostgreSQL..."
if docker compose -f "$INSTALL_DIR/docker-compose.yml" ps postgres | grep -q "running"; then
    docker compose -f "$INSTALL_DIR/docker-compose.yml" exec -T postgres \
        pg_dump -U przma przma | gzip > "$BACKUP_DIR/postgres_$DATE.sql.gz"
    log "PostgreSQL backup: $BACKUP_DIR/postgres_$DATE.sql.gz ($(du -h "$BACKUP_DIR/postgres_$DATE.sql.gz" | cut -f1))"
else
    log "Warning: PostgreSQL not running — skipping database backup"
fi

# ── 3. Backup configuration ────────────────────────────────────────────────────
log "Backing up configuration..."
tar czf "$BACKUP_DIR/config_$DATE.tar.gz" \
    -C "$INSTALL_DIR" \
    --exclude='.env' \
    docker-compose.yml Caddyfile 2>/dev/null || true
# Note: .env is excluded because it contains secrets.
# Back it up separately to a secure location.

# ── 4. Remote backup (optional) ───────────────────────────────────────────────
if command -v rclone &>/dev/null && [ -n "${BACKUP_REMOTE:-}" ]; then
    log "Syncing to remote: $BACKUP_REMOTE"
    rclone copy "$BACKUP_DIR" "$BACKUP_REMOTE" \
        --max-age "${KEEP_DAYS}d" \
        --log-level INFO
    log "Remote sync complete"
fi

# ── 5. Clean up old local backups ─────────────────────────────────────────────
log "Removing backups older than $KEEP_DAYS days..."
find "$BACKUP_DIR" -type f -name "*.tar.gz" -mtime "+$KEEP_DAYS" -delete
find "$BACKUP_DIR" -type f -name "*.sql.gz" -mtime "+$KEEP_DAYS" -delete

BACKUP_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1 || echo "?")
log "Backup complete. Total backup dir size: $BACKUP_SIZE"
log "Backups stored in: $BACKUP_DIR"
