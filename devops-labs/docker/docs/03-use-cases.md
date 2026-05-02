# Docker Real-World Use Cases

## 1. Local Development Environment

```yaml
# docker-compose.dev.yml — mirrors production closely
# Start: docker compose -f docker-compose.dev.yml up
services:
  api:
    build:
      context: .
      target: development    # Dev stage with hot reload
    volumes:
      - ./src:/app/src       # Live code reload
    ports:
      - "3000:3000"
      - "9229:9229"          # Node.js debugger
    environment:
      NODE_ENV: development
      DEBUG: "app:*"

  # Same postgres version as production
  db:
    image: postgres:15-alpine
    ports:
      - "5432:5432"          # Expose for local tools

  # Redis with UI
  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"

  redis-ui:
    image: rediscommander/redis-commander
    ports:
      - "8081:8081"
    environment:
      REDIS_HOSTS: local:redis:6379
    profiles:
      - tools

  # PGAdmin for database browsing
  pgadmin:
    image: dpage/pgadmin4
    ports:
      - "5050:80"
    environment:
      PGADMIN_DEFAULT_EMAIL: dev@local.dev
      PGADMIN_DEFAULT_PASSWORD: local
    profiles:
      - tools
```

---

## 2. Immutable Infrastructure Pattern

```bash
# PATTERN: Never update a running container. Replace it.

# Build with exact version
docker build -t myapp:v2.3.1 --label version=v2.3.1 .

# Push to registry
docker push myregistry.io/myapp:v2.3.1

# Deploy by replacing (blue/green):
# 1. Start new container
docker run -d --name myapp-v2 -p 8081:8080 myregistry.io/myapp:v2.3.1

# 2. Health check passes
curl http://localhost:8081/health

# 3. Switch load balancer port
# (nginx reload, HAProxy config update, etc.)

# 4. Stop old container
docker stop myapp-v1
docker rm myapp-v1

# NEVER: docker exec -it myapp bash && apt-get install vim && vim config.py
# That changes what's running but not the image. Next deploy loses the change.
```

---

## 3. Database Migration Pattern

```dockerfile
# Separate migration image
FROM python:3.12-slim AS migrations
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY migrations/ ./migrations/
COPY alembic.ini .

# Different CMD: runs migration, then exits
CMD ["alembic", "upgrade", "head"]
```

```yaml
# docker-compose.yml
services:
  migrate:
    image: myapp:latest
    command: alembic upgrade head
    environment:
      DATABASE_URL: postgresql://user:pass@db:5432/mydb
    depends_on:
      db:
        condition: service_healthy
    restart: "no"          # Don't restart after migration completes

  app:
    image: myapp:latest
    depends_on:
      migrate:
        condition: service_completed_successfully   # Wait for migration
```

---

## 4. Sidecar Pattern for Logging

```yaml
# One container writes logs, another ships them
services:
  app:
    image: myapp:latest
    volumes:
      - logs:/app/logs         # Shared volume

  log-shipper:
    image: fluent/fluentd:v1.16
    volumes:
      - logs:/fluentd/log:ro   # Read-only access to app logs
      - ./fluentd.conf:/fluentd/etc/fluent.conf:ro
    depends_on:
      - app

volumes:
  logs:
```

---

## 5. Docker for ML/AI Workloads

```dockerfile
# GPU-enabled Python container for ML
FROM nvidia/cuda:12.3.0-runtime-ubuntu22.04 AS gpu-base

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.12 python3-pip && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

FROM gpu-base AS training
COPY requirements-ml.txt .
RUN pip install -r requirements-ml.txt    # torch, transformers, etc.
COPY train.py .
CMD ["python", "train.py"]

FROM gpu-base AS inference
COPY requirements-inference.txt .
RUN pip install -r requirements-inference.txt    # minimal set
COPY serve.py models/ ./
CMD ["python", "serve.py"]
```

```bash
# Run with GPU
docker run --gpus all -v $(pwd)/models:/workspace/models myml:training

# Check GPU access
docker run --gpus all nvidia/cuda:12.3.0-base nvidia-smi
```

---

## 6. Zero-Downtime Deploy with Docker

```bash
#!/bin/bash
# zero-downtime-deploy.sh
set -e

IMAGE="$1"
SERVICE="myapp"
NEW_CONTAINER="${SERVICE}-new"
OLD_CONTAINER="${SERVICE}-old"
CURRENT_CONTAINER="${SERVICE}"

echo "Deploying $IMAGE..."

# 1. Start new container on a different internal port
docker run -d \
  --name $NEW_CONTAINER \
  --network myapp-network \
  -e APP_ENV=production \
  $IMAGE

# 2. Wait for health check to pass
echo "Waiting for new container to be healthy..."
for i in $(seq 1 30); do
  STATUS=$(docker inspect --format='{{.State.Health.Status}}' $NEW_CONTAINER 2>/dev/null || echo "unknown")
  [ "$STATUS" = "healthy" ] && break
  echo "  Status: $STATUS (attempt $i/30)"
  sleep 2
done

[ "$STATUS" != "healthy" ] && { 
  echo "❌ New container unhealthy!"
  docker rm -f $NEW_CONTAINER
  exit 1
}

# 3. Rename containers (atomic switch)
docker rename $CURRENT_CONTAINER $OLD_CONTAINER
docker rename $NEW_CONTAINER $CURRENT_CONTAINER

# 4. Update nginx upstream (hot reload)
docker exec nginx nginx -s reload

# 5. Stop old container
sleep 5   # Allow in-flight requests to complete
docker stop $OLD_CONTAINER
docker rm $OLD_CONTAINER

echo "✅ Zero-downtime deploy complete!"
```
