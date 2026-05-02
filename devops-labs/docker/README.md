# Docker

> **Build, ship, and run containers. From dev laptop to production.**

---

## Quick Navigation

| Section | Contents |
|---------|----------|
| [docs/01-concepts.md](docs/01-concepts.md) | Container model, images, layers, networking |
| [docs/02-best-practices.md](docs/02-best-practices.md) | Production Dockerfiles, security, optimization |
| [examples/](examples/) | 10 real-world Dockerfiles and compose files |
| [labs/](labs/) | 3 hands-on labs |
| [interview-prep/questions.md](interview-prep/questions.md) | 15 interview Q&A |

---

## 5-Minute Cheatsheet

```bash
# Build
docker build -t myapp:1.0 .
docker build -t myapp:1.0 --no-cache .
docker build --target production -t myapp:prod .  # Multi-stage

# Run
docker run -d -p 8080:80 --name web nginx:alpine
docker run -it --rm ubuntu:22.04 bash             # Interactive, auto-remove
docker run -v $(pwd)/data:/app/data myapp:1.0      # Volume mount

# Inspect
docker ps -a
docker logs web -f --tail=50
docker exec -it web sh
docker inspect web | jq '.[0].NetworkSettings'

# Images
docker images
docker pull redis:7-alpine
docker tag myapp:1.0 registry.io/myapp:1.0
docker push registry.io/myapp:1.0
docker rmi myapp:1.0

# Cleanup (reclaim disk)
docker system prune -af --volumes

# Compose
docker compose up -d
docker compose logs -f api
docker compose down -v
docker compose ps
```
