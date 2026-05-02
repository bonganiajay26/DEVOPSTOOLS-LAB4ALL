# Docker Core Concepts

## Containers vs VMs

```
Virtual Machine:
┌──────────────────────────────────────────┐
│  App A  │  App B  │  App C              │
├─────────┼─────────┼─────────            │
│ Guest OS│ Guest OS│ Guest OS (3 × ~1GB) │
├──────────────────────────────────────────┤
│           Hypervisor                     │
├──────────────────────────────────────────┤
│           Host OS                        │
└──────────────────────────────────────────┘

Container:
┌──────────────────────────────────────────┐
│  App A  │  App B  │  App C              │
├──────────────────────────────────────────┤
│           Docker Engine                  │  ← Shared kernel
├──────────────────────────────────────────┤
│           Host OS + Kernel               │
└──────────────────────────────────────────┘

Containers: start in <1s, use ~5-50MB overhead
VMs:        start in 30-60s, use 1GB+ overhead
```

Containers use Linux kernel features:
- **Namespaces**: Isolate PID, network, filesystem, users
- **cgroups**: Limit CPU, memory, I/O
- **Union filesystem**: Layered image system (OverlayFS)

---

## Image Layers

```
Image: nginx:1.25
├── Layer 1 (debian:bookworm-slim base)   35 MB
├── Layer 2 (nginx package install)       25 MB
├── Layer 3 (nginx config)                 1 MB
└── Layer 4 (your static files)            5 MB
     Total:                               66 MB

Each RUN/COPY/ADD in Dockerfile = one layer.
Layers are cached and shared between images.
```

```dockerfile
# Each instruction = a layer
FROM node:20-alpine         # Layer 1 (base)
WORKDIR /app                # Layer 2
COPY package.json .         # Layer 3 (changes rarely → cache hit)
RUN npm ci                  # Layer 4 (expensive → cache hit when package.json unchanged)
COPY . .                    # Layer 5 (changes every build)
RUN npm run build           # Layer 6
```

**Layer caching rule**: Put things that change LEAST at the top, most at the bottom.

---

## Docker Networking

```
Network modes:
  bridge   → Virtual switch on host (default). Containers get own IPs.
  host     → Container shares host network namespace (no isolation)
  none     → No networking
  overlay  → Multi-host networking (Docker Swarm/K8s)

Container DNS:
  Within user-defined bridge network:
  container A can reach container B by name: http://container-b:8080

  Default bridge network: no DNS, must use IP addresses.
  → Always create user-defined networks!
```

```bash
# Create network
docker network create myapp-network

# Connect containers to named network (they can find each other by name)
docker run -d --name postgres --network myapp-network postgres:15
docker run -d --name api --network myapp-network -e DB_HOST=postgres myapp:1.0
#                                                             ↑ resolves via Docker DNS
```

---

## Volumes vs Bind Mounts

```
Volume:
  docker run -v mydata:/app/data nginx
  Stored in Docker-managed location (/var/lib/docker/volumes/)
  Portable, shareable, best for production data

Bind Mount:
  docker run -v $(pwd)/src:/app/src nginx
  Maps host path directly into container
  Best for development (live code reload)

tmpfs Mount:
  docker run --tmpfs /tmp:noexec,nosuid,size=100m nginx
  In-memory only, never written to disk
  Best for sensitive temp files
```

---

## docker-compose vs Docker

- **Docker**: Single container operations
- **docker-compose**: Multi-container applications (defines services, networks, volumes)
- **Kubernetes**: Production orchestration for large scale

```yaml
# docker-compose.yml — development environment
services:
  api:
    build: ./api
    ports: ["3000:3000"]
    volumes: ["./api:/app"]       # Live reload
    depends_on:
      postgres:
        condition: service_healthy

  postgres:
    image: postgres:15-alpine
    environment:
      POSTGRES_PASSWORD: devpassword
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "postgres"]
      interval: 5s
      retries: 5
    volumes:
      - pgdata:/var/lib/postgresql/data

volumes:
  pgdata:
```
