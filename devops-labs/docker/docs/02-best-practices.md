# Docker Production Best Practices

## 1. Image Optimization

```dockerfile
# ❌ BAD: bloated, insecure, non-reproducible
FROM ubuntu:latest
RUN apt-get install -y python3 pip nodejs npm
COPY . .
RUN pip install -r requirements.txt && npm install
CMD python app.py

# ✅ GOOD: lean, pinned, multi-stage
FROM python:3.12-slim AS base
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq-dev=15* \
    && rm -rf /var/lib/apt/lists/*

FROM base AS builder
COPY requirements.txt .
RUN pip install --prefix=/install -r requirements.txt

FROM base AS production
RUN useradd --uid 1001 appuser
COPY --from=builder /install /usr/local
COPY --chown=appuser:appuser src/ /app/
USER appuser
WORKDIR /app
EXPOSE 8080
CMD ["python", "-m", "gunicorn", "-b", "0.0.0.0:8080", "app:app"]
```

### Image Size Comparison

| Approach | Image Size |
|---------|-----------|
| ubuntu:latest + pip | ~1.2 GB |
| python:3.12 | ~1.0 GB |
| python:3.12-slim | ~150 MB |
| python:3.12-alpine | ~55 MB |
| Multi-stage (slim) | ~80 MB |

---

## 2. .dockerignore — Always Use It

```dockerignore
# .dockerignore
# Version control
.git/
.gitignore

# Development files
.env*
*.local
docker-compose*.yml
Dockerfile*

# Python
__pycache__/
*.pyc
*.pyo
.pytest_cache/
.coverage
htmlcov/
.venv/
*.egg-info/

# Node
node_modules/
npm-debug.log*
.next/
dist/

# IDE
.idea/
.vscode/
*.swp

# CI/CD
.github/
.gitlab-ci.yml
Jenkinsfile

# Documentation
docs/
*.md
LICENSE
README*

# Tests
tests/
test_*
*_test.*
```

---

## 3. Security Hardening

```dockerfile
FROM node:20-alpine AS production

# Non-root user
RUN addgroup -g 1001 -S nodejs && \
    adduser -S nextjs -u 1001

# Read-only filesystem
# (requires tmpfs mounts for /tmp, /var/run, etc.)

# Drop all capabilities
# In docker-compose.yml:
# security_opt:
#   - no-new-privileges:true
# cap_drop:
#   - ALL
# cap_add:
#   - NET_BIND_SERVICE  (only if binding to port < 1024)

# Use COPY not ADD (ADD can extract archives, security risk)
COPY --chown=nextjs:nodejs .next ./.next
COPY --chown=nextjs:nodejs public ./public

# Switch to non-root
USER nextjs

EXPOSE 3000
ENV PORT 3000

CMD ["node", "server.js"]
```

### Runtime Security Options

```bash
# Run with security hardening
docker run \
  --user 1000:1000 \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=100m \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --security-opt seccomp=default.json \
  --memory=512m \
  --cpus=0.5 \
  myapp:latest
```

---

## 4. Health Checks

```dockerfile
# HTTP health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

# TCP health check (for non-HTTP services)
HEALTHCHECK --interval=10s --timeout=5s --retries=3 \
    CMD nc -z localhost 5432 || exit 1

# Custom script health check
COPY healthcheck.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/healthcheck.sh
HEALTHCHECK --interval=30s CMD /usr/local/bin/healthcheck.sh
```

---

## 5. Layer Caching Strategy

```dockerfile
# RULE: Order from LEAST CHANGED to MOST CHANGED

FROM python:3.12-slim

# 1. System deps (changes rarely → always cached)
RUN apt-get update && apt-get install -y libpq-dev && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 2. Dependency files (changes on new package add)
COPY requirements.txt requirements-dev.txt ./

# 3. Install dependencies (long step — cache hit when requirements unchanged)
RUN pip install --no-cache-dir -r requirements.txt

# 4. Application source (changes every commit — runs every build)
COPY src/ ./src/

CMD ["python", "src/app.py"]
```

---

## 6. Docker Compose for Production-Like Dev

```yaml
# docker-compose.yml
services:
  app:
    build:
      context: .
      target: production
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    environment:
      DATABASE_URL: postgresql://user:pass@db:5432/mydb
      REDIS_URL: redis://redis:6379/0
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: 512M
        reservations:
          cpus: '0.1'
          memory: 128M
    logging:
      driver: json-file
      options:
        max-size: "100m"
        max-file: "3"

  db:
    image: postgres:15-alpine
    restart: unless-stopped
    environment:
      POSTGRES_PASSWORD: pass
      POSTGRES_USER: user
      POSTGRES_DB: mydb
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U user -d mydb"]
      interval: 5s
      timeout: 3s
      retries: 5

  redis:
    image: redis:7-alpine
    restart: unless-stopped
    command: redis-server --maxmemory 128mb --maxmemory-policy allkeys-lru
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s

volumes:
  pgdata:
```

---

## 7. Container Scanning

```bash
# Scan before push (in CI)

# Trivy (comprehensive, free)
trivy image myapp:latest
trivy image --exit-code 1 --severity HIGH,CRITICAL myapp:latest

# Grype
grype myapp:latest

# Docker Scout (built-in)
docker scout cves myapp:latest
docker scout recommendations myapp:latest

# Hadolint (Dockerfile linting)
hadolint Dockerfile

# Dockle (best practices)
dockle myapp:latest
```

---

## 8. Multi-Platform Builds

```bash
# Build for multiple CPU architectures (amd64 + arm64)
# Required for: M1/M2 Macs, AWS Graviton, Raspberry Pi

# Setup buildx
docker buildx create --use --name multiarch
docker buildx inspect --bootstrap

# Build and push multi-arch
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --tag myregistry.io/myapp:latest \
  --push \
  .

# Verify manifest
docker manifest inspect myregistry.io/myapp:latest
```
