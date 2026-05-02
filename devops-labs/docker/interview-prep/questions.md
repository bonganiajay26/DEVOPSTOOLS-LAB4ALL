# Docker Interview Questions

## Q1. What is the difference between an image and a container?

**Image**: Read-only template. Blueprint. Stored on disk. Can be shared via registry.
**Container**: Running instance of an image. Has a writable layer on top. Ephemeral by default.

```bash
# Image = class definition. Container = object instance.
docker images                         # List images on disk
docker ps                             # List running containers (instances)
docker run nginx:alpine               # Creates container FROM image

# You can run 10 containers from the same image
docker run -d --name web1 nginx:alpine
docker run -d --name web2 nginx:alpine
docker run -d --name web3 nginx:alpine
```

---

## Q2. Explain Docker image layers and layer caching.

Each instruction in a Dockerfile creates a **read-only layer**. Layers are shared across images (stored once on disk).

```dockerfile
# BAD — invalidates cache on every source change
FROM python:3.12-slim
COPY . .                    # Any file change → cache miss for all following layers
RUN pip install -r requirements.txt

# GOOD — copy requirements first, source code last
FROM python:3.12-slim
COPY requirements.txt .     # Only reinstalls deps when requirements.txt changes
RUN pip install -r requirements.txt
COPY . .                    # Source change only rebuilds this layer forward
```

**Cache invalidation rules:**
- Any layer change invalidates ALL following layers
- `COPY`/`ADD` checks file checksum, not timestamp
- Use `--no-cache` to bypass: `docker build --no-cache`

---

## Q3. How do you reduce Docker image size?

```dockerfile
# 1. Use alpine base images
FROM python:3.12-alpine      # ~23MB vs python:3.12 ~1GB

# 2. Multi-stage builds — don't ship build tools
FROM node:20 AS builder
RUN npm ci && npm run build

FROM node:20-alpine AS prod   # Only ~50MB base
COPY --from=builder /app/dist /app/dist

# 3. Minimize layers — combine RUN commands
RUN apt-get update && \
    apt-get install -y --no-install-recommends gcc libpq-dev && \
    rm -rf /var/lib/apt/lists/*   # Clean in SAME layer!

# 4. .dockerignore — don't copy unnecessary files
# node_modules/, .git/, *.log, .env

# 5. Use specific versions (avoids pulling bloated :latest)
FROM nginx:1.25-alpine         # 15MB vs nginx:latest 45MB
```

---

## Q4. Container is crashing immediately. How do you debug it?

```bash
# 1. Check exit code
docker ps -a | grep myapp
# Status: Exited (1)  — code 1 = app error
# Status: Exited (137) — OOM killed

# 2. Read logs (including after crash)
docker logs myapp --tail=50
docker logs myapp --previous   # Not available for docker — use K8s

# 3. Override entrypoint to debug
docker run -it --entrypoint sh myapp:latest
# Now explore filesystem, run app manually

# 4. Check environment variables
docker inspect myapp | jq '.[0].Config.Env'

# 5. Check if port is already in use
docker run -p 8080:8080 myapp
# Error: bind: address already in use
lsof -i :8080
```

---

## Q5. What is the difference between CMD and ENTRYPOINT?

```dockerfile
# CMD: default command. Can be overridden at runtime.
CMD ["python", "app.py"]
# docker run myimage              → runs: python app.py
# docker run myimage bash         → runs: bash (overrides CMD)

# ENTRYPOINT: executable that always runs. CMD becomes its arguments.
ENTRYPOINT ["python"]
CMD ["app.py"]
# docker run myimage              → runs: python app.py
# docker run myimage manage.py migrate → runs: python manage.py migrate

# Best practice: ENTRYPOINT for the executable, CMD for default args
ENTRYPOINT ["gunicorn"]
CMD ["--workers=4", "--bind=0.0.0.0:8000", "myapp.wsgi:application"]
# Override in K8s:
# args: ["--workers=2", "--bind=0.0.0.0:8000", "myapp.wsgi:application"]
```

---

## Q6. How do you handle secrets in Docker? What NOT to do?

```bash
# ❌ NEVER: put secrets in ENV in Dockerfile
ENV DATABASE_PASSWORD=mysecret   # Gets baked into image layer FOREVER

# ❌ NEVER: pass secrets in build args (visible in docker history)
docker build --build-arg SECRET_KEY=abc123 .
docker history myimage           # SECRET_KEY visible here!

# ✅ Runtime env vars (not in image, injected at run time)
docker run -e DATABASE_URL="postgresql://..." myimage
docker run --env-file .env myimage    # .env is gitignored

# ✅ Docker secrets (Swarm mode)
docker secret create db_password ./db_password.txt
# In compose: secrets: [db_password] — mounts as /run/secrets/db_password

# ✅ Vault agent sidecar (production)
# Vault injects secret as file at container startup

# ✅ Scan images for secrets before push
docker scan myimage
trivy image myimage
```

---

## Q7. Explain Docker networking modes.

```bash
# bridge (default) — containers get own IPs on docker0 bridge
docker run nginx                    # IP: 172.17.0.x

# user-defined bridge — adds container DNS resolution
docker network create mynet
docker run --network mynet --name db postgres
docker run --network mynet --name api -e DB_HOST=db myapp
# 'db' resolves to postgres container IP

# host — container shares host network (no isolation, best perf)
docker run --network host nginx     # nginx listens on HOST:80

# none — no network
docker run --network none myapp     # Completely isolated

# overlay — multi-host (Docker Swarm / K8s)

# Inspect network
docker network inspect mynet
docker inspect container --format '{{.NetworkSettings.Networks}}'
```

---

## Q8. What is a multi-stage build? Why use it?

Multi-stage = multiple `FROM` statements in one Dockerfile. Only the final stage is in the resulting image.

```
Without multi-stage:
  golang:1.21 base = 850MB
  + source code + build tools
  Final image = 900MB  😱

With multi-stage:
  Stage 1 (builder): golang:1.21 — compiles binary
  Stage 2 (runtime): scratch — only the binary
  Final image = 10MB  ✅
```

```dockerfile
FROM golang:1.21 AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /app ./cmd/server

FROM scratch AS production        # Empty image — just the OS minimum
COPY --from=builder /app /app
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
EXPOSE 8080
USER 65534:65534                  # nobody user
ENTRYPOINT ["/app"]
```

---

## Q9. How do you run Docker containers securely?

```bash
# 1. Run as non-root
docker run --user 1000:1000 myimage

# 2. Read-only filesystem
docker run --read-only --tmpfs /tmp myimage

# 3. Drop all capabilities
docker run --cap-drop=ALL --cap-add=NET_BIND_SERVICE myimage

# 4. No privilege escalation
docker run --security-opt=no-new-privileges myimage

# 5. Limit resources (prevent runaway containers)
docker run --memory=512m --cpus=0.5 myimage

# 6. Seccomp profile (restrict syscalls)
docker run --security-opt seccomp=my-seccomp-profile.json myimage

# Combined:
docker run -d \
  --user 1000:1000 \
  --read-only \
  --tmpfs /tmp:noexec,nosuid,size=100m \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --memory=512m --memory-swap=512m \
  --cpus=0.5 \
  myimage:latest
```

---

## Q10. Container exits with code 137. What happened?

Exit code 137 = killed by SIGKILL = **Out of Memory (OOM)**.

```bash
# Confirm
docker inspect myapp | jq '.[0].State.OOMKilled'
# true

# Check resource usage
docker stats myapp

# Fix: increase memory limit
docker run --memory=2g myapp

# Prevent: set both --memory and --memory-swap equal (no swap)
docker run --memory=1g --memory-swap=1g myapp

# In K8s: check pod events
kubectl describe pod myapp | grep -i oom
# OOMKilled → increase memory limits in pod spec
```

---

## Q11. How do volumes work? When do you use each type?

```bash
# Named volume — Docker manages location
# Best for: production databases, persistent data you don't need to browse
docker run -v postgres_data:/var/lib/postgresql/data postgres

# Bind mount — maps host directory
# Best for: development (live reload), accessing host files
docker run -v $(pwd)/src:/app/src myapp

# tmpfs — in memory, never persisted
# Best for: sensitive data (passwords, tokens that shouldn't touch disk)
docker run --tmpfs /run/secrets:noexec,nosuid,mode=0700 myapp

# Inspect volumes
docker volume ls
docker volume inspect postgres_data

# Backup named volume
docker run --rm \
  -v postgres_data:/source:ro \
  -v $(pwd):/backup \
  alpine tar czf /backup/pgdata.tar.gz -C /source .
```

---

## Q12. How do you scan Docker images for vulnerabilities?

```bash
# Trivy (most popular, free)
trivy image myimage:latest

# Scan in CI (fail on CRITICAL/HIGH)
trivy image --exit-code 1 --severity CRITICAL,HIGH myimage:latest

# Scan specific CVE
trivy image --ignore-unfixed myimage:latest

# Docker Scout (built into Docker Desktop)
docker scout cves myimage:latest
docker scout recommendations myimage:latest

# Grype (Anchore)
grype myimage:latest

# Snyk
snyk container test myimage:latest

# Scan Dockerfile for best practices
hadolint Dockerfile
```

---

## Q13. What is the difference between `docker stop` and `docker kill`?

```bash
# docker stop — graceful shutdown
# Sends SIGTERM → app can handle cleanup → waits 10s → sends SIGKILL
docker stop mycontainer             # Graceful
docker stop --time=30 mycontainer   # Wait 30s before SIGKILL

# docker kill — immediate termination
# Sends SIGKILL directly (or specified signal)
docker kill mycontainer             # No cleanup possible
docker kill --signal=SIGUSR1 mycontainer  # Send custom signal (e.g., reload config)
```

**Application responsibility**: Handle SIGTERM gracefully — close DB connections, finish in-flight requests, save state.

---

## Q14. How do you implement health checks in Docker?

```dockerfile
# Dockerfile HEALTHCHECK
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

# For TCP (no curl available)
HEALTHCHECK CMD nc -z localhost 5432 || exit 1

# Check status
docker inspect mycontainer | jq '.[0].State.Health'
docker ps   # STATUS shows: healthy / unhealthy / starting

# docker-compose healthcheck
services:
  api:
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
```

---

## Q15. You're seeing intermittent 503 errors from a containerized app. How do you investigate?

```bash
# 1. Real-time resource usage
docker stats                        # CPU/Memory/Network/IO per container

# 2. Container logs with timestamps
docker logs myapp --timestamps --since=1h 2>&1 | grep -E "error|ERROR|503"

# 3. Is container restarting? (crash loop)
docker ps -a | grep myapp           # Check Restart count

# 4. Network connectivity
docker exec -it myapp curl -v http://postgres:5432  # Can container reach dependencies?

# 5. Resource limits hit?
docker inspect myapp | jq '.[0].HostConfig | {Memory, CpuPeriod, CpuQuota}'
docker stats myapp --no-stream      # One-time snapshot

# 6. OS-level view
docker top myapp                    # Processes inside container
docker exec -it myapp top           # Interactive top inside container

# 7. Check for zombie processes or file descriptor leaks
docker exec myapp sh -c "ls /proc | wc -l"
docker exec myapp sh -c "cat /proc/sys/fs/file-nr"

# Most common causes:
# - Memory limit too low → OOM → crash → 503 during restart
# - CPU throttling → slow → timeouts → 503
# - DB connection pool exhausted → queued requests → timeout → 503
# - Dependency down → health check fails → removed from LB → 503
```
