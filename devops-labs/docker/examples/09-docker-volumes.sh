#!/bin/bash
# Example 09: Docker Volumes — Persistence, Backup, and Migration

echo "=== Docker Volume Management ==="

# ── 1. Named volumes (production data) ────────────────────────
echo "--- Named volumes ---"

# Create named volume
docker volume create postgres-data
docker volume create app-uploads

# List volumes
docker volume ls

# Inspect volume
docker volume inspect postgres-data
# Shows: mount path on host, driver, labels

# Use volume
docker run -d \
  --name postgres \
  -v postgres-data:/var/lib/postgresql/data \
  -e POSTGRES_PASSWORD=test \
  postgres:15-alpine

# Write some data
sleep 3
docker exec postgres psql -U postgres -c "CREATE DATABASE myapp;"
docker exec postgres psql -U postgres -c "CREATE TABLE users (id SERIAL, name TEXT);"
docker exec postgres psql -U postgres -d myapp -c "INSERT INTO users VALUES (1, 'Alice');"

# Stop and remove container — data PERSISTS in volume
docker rm -f postgres

# Start new container with same volume — data is there!
docker run -d \
  --name postgres-new \
  -v postgres-data:/var/lib/postgresql/data \
  -e POSTGRES_PASSWORD=test \
  postgres:15-alpine

sleep 3
docker exec postgres-new psql -U postgres -d myapp -c "SELECT * FROM users;"
# Alice is still there! ✅

docker rm -f postgres-new

# ── 2. Volume backup ──────────────────────────────────────────
echo ""
echo "--- Volume backup ---"

# Backup a volume to tar archive
docker run --rm \
  -v postgres-data:/data:ro \
  -v $(pwd)/backups:/backup \
  alpine \
  tar czf /backup/postgres-data-$(date +%Y%m%d).tar.gz -C /data .

ls -lh backups/

# ── 3. Volume restore ─────────────────────────────────────────
echo ""
echo "--- Volume restore ---"

# Create new volume
docker volume create postgres-restore

# Restore from backup
docker run --rm \
  -v postgres-restore:/data \
  -v $(pwd)/backups:/backup:ro \
  alpine \
  sh -c "tar xzf /backup/postgres-data-$(date +%Y%m%d).tar.gz -C /data"

echo "✅ Volume restored"

# ── 4. Bind mounts for development ────────────────────────────
echo ""
echo "--- Bind mounts (development) ---"

mkdir -p ./myapp-dev
echo "print('Hello!')" > ./myapp-dev/app.py

# Mount local directory into container (live reload!)
docker run --rm \
  -v $(pwd)/myapp-dev:/app \
  -w /app \
  python:3.12-slim \
  python app.py
# File changes on host are immediately visible in container

# ── 5. tmpfs (in-memory, ephemeral) ──────────────────────────
echo ""
echo "--- tmpfs (sensitive data) ---"

docker run --rm \
  --tmpfs /run/secrets:rw,noexec,nosuid,mode=0700,size=10m \
  alpine \
  sh -c "echo 'mysecretpassword' > /run/secrets/db-pass && cat /run/secrets/db-pass"
# /run/secrets is in RAM only, never written to disk

# ── 6. Cleanup ────────────────────────────────────────────────
echo ""
echo "--- Cleanup ---"

# Remove specific volumes
docker volume rm postgres-data postgres-restore app-uploads 2>/dev/null || true

# Remove ALL unused volumes (careful in production!)
# docker volume prune -f

# Full system cleanup
# docker system prune -af --volumes

rm -rf backups myapp-dev 2>/dev/null || true
echo "✅ Cleanup complete"
