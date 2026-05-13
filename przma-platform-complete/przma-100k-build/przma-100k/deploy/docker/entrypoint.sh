#!/bin/bash
# deploy/docker/entrypoint.sh
# Docker entrypoint for PRZMA — runs migrations then starts Phoenix.

set -e

echo "PRZMA starting..."

# Run Ecto migrations (creates Oban tables in PostgreSQL)
if [ "${PRZMA_MODE}" != "local" ]; then
    echo "Running database migrations..."
    /app/bin/przma eval "PRZMA.Release.migrate()"
fi

# Start Phoenix
echo "Starting PRZMA (mode: ${PRZMA_MODE:-own_domain})..."
exec /app/bin/przma "${1:-start}"
