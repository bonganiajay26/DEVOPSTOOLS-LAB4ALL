#!/bin/bash
# Example 08: Docker Networking Deep Dive

echo "=== Docker Networking Examples ==="

# ── 1. Default bridge network (no DNS) ───────────────────────
echo "--- Default bridge ---"
docker network inspect bridge | jq '.[0].IPAM.Config'

# Containers on default bridge can't find each other by name
docker run -d --name db1 postgres:15-alpine
docker run -d --name app1 busybox sleep 3600
docker exec app1 ping db1 || echo "Expected: FAIL - no DNS on default bridge"

docker rm -f db1 app1 2>/dev/null

# ── 2. User-defined bridge (DNS enabled) ──────────────────────
echo ""
echo "--- User-defined bridge (recommended) ---"
docker network create myapp-net

docker run -d --name postgres \
  --network myapp-net \
  -e POSTGRES_PASSWORD=test \
  postgres:15-alpine

docker run --rm --network myapp-net \
  curlimages/curl:latest \
  nslookup postgres
# DNS resolves! 'postgres' → container IP

docker rm -f postgres
docker network rm myapp-net

# ── 3. Isolate services with multiple networks ─────────────────
echo ""
echo "--- Multi-network isolation ---"

docker network create frontend-net
docker network create backend-net

# Frontend: only in frontend-net
docker run -d --name frontend --network frontend-net nginx:alpine

# API: in both networks (bridge between frontend and backend)
docker run -d --name api \
  --network frontend-net \
  busybox sh -c "while true; do echo 'api running'; sleep 10; done"
docker network connect backend-net api

# Database: only in backend-net (frontend CANNOT reach it directly!)
docker run -d --name db \
  --network backend-net \
  -e POSTGRES_PASSWORD=test \
  postgres:15-alpine

echo "Frontend → API: $(docker exec frontend ping -c1 api &>/dev/null && echo 'REACHABLE' || echo 'BLOCKED')"
echo "Frontend → DB:  $(docker exec frontend ping -c1 db &>/dev/null && echo 'REACHABLE' || echo 'BLOCKED')"
echo "API → DB:       $(docker exec api ping -c1 db &>/dev/null && echo 'REACHABLE' || echo 'BLOCKED')"

docker rm -f frontend api db
docker network rm frontend-net backend-net

# ── 4. Host networking (highest performance, no isolation) ─────
echo ""
echo "--- Host network mode ---"
# Container shares host's network namespace
# Useful for: performance, raw socket access, debugging
docker run --rm --network host nginx:alpine &
sleep 2
curl -s http://localhost:80 | head -5
kill %1 2>/dev/null

# ── 5. None network (complete isolation) ──────────────────────
echo ""
echo "--- None network (isolated) ---"
docker run --rm --network none alpine \
  sh -c "ip addr show" || echo "No network interfaces!"

# ── 6. Network aliases ────────────────────────────────────────
echo ""
echo "--- Network aliases (multiple names for same container) ---"
docker network create alias-test
docker run -d \
  --name my-database \
  --network alias-test \
  --network-alias db \
  --network-alias postgres \
  -e POSTGRES_PASSWORD=test \
  postgres:15-alpine

# Can reach it as: my-database, db, or postgres
docker run --rm --network alias-test curlimages/curl:latest \
  nslookup db

docker rm -f my-database
docker network rm alias-test

echo "=== Done ==="
