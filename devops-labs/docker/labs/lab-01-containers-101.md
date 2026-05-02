# Lab 01: Docker Containers 101 — From Process to Production

**Difficulty**: Beginner | **Time**: 45 minutes  
**Goal**: Understand containers, images, and layers from first principles.

---

## Part 1: Containers Are Just Processes

```bash
# Start a container
docker run -d --name web nginx:alpine
docker ps

# A container is a process on the HOST
ps aux | grep nginx
# See the nginx process! It's running on your machine.

# Check the PID namespace isolation
docker exec web ps aux     # Shows only web's processes
ps aux | grep -c nginx     # Host sees them too (different PIDs)

# Stop the container = kill the process
docker stop web
ps aux | grep nginx   # Gone!
docker rm web
```

---

## Part 2: Image Layers — Inspect the Cache

```bash
# See all layers of an image
docker history nginx:alpine

# Pull nginx and a variant
docker pull nginx:1.24-alpine
docker pull nginx:1.25-alpine

# Check disk usage — layers are SHARED
docker system df
docker images | grep nginx

# Look at layer IDs — identical layers are shared on disk
docker inspect nginx:1.24-alpine | jq '.[0].RootFS.Layers'
docker inspect nginx:1.25-alpine | jq '.[0].RootFS.Layers'
# Several layers are identical (base OS layers)
```

---

## Part 3: Build Your Own Image

```bash
mkdir docker-lab && cd docker-lab

# Create a simple Python app
cat > app.py << 'EOF'
from http.server import HTTPServer, BaseHTTPRequestHandler
import json
import os

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        response = {
            "message": "Hello from Docker!",
            "hostname": os.uname().nodename,
            "path": self.path
        }
        self.wfile.write(json.dumps(response).encode())

    def log_message(self, format, *args):
        print(f"{self.client_address[0]} - {args[0]}")

if __name__ == "__main__":
    port = int(os.getenv("PORT", 8080))
    print(f"Server starting on port {port}...")
    HTTPServer(("", port), Handler).serve_forever()
EOF

# Write the Dockerfile
cat > Dockerfile << 'EOF'
FROM python:3.12-alpine

WORKDIR /app

COPY app.py .

EXPOSE 8080

CMD ["python", "app.py"]
EOF

# Build it
docker build -t myserver:v1 .

# See the layers created
docker history myserver:v1

# Run it
docker run -d -p 8080:8080 --name myserver myserver:v1

# Test it
curl http://localhost:8080
curl http://localhost:8080/api/users

# See container ID = hostname
docker inspect myserver --format='{{.Id}}' | cut -c1-12
curl http://localhost:8080 | jq .hostname
# Should match! The container ID IS the hostname.
```

---

## Part 4: Environment Variables and Configuration

```bash
# Environment variables are the right way to configure containers
cat > Dockerfile << 'EOF'
FROM python:3.12-alpine
WORKDIR /app
COPY app.py .
ENV APP_ENV=production
ENV PORT=8080
EXPOSE 8080
CMD ["python", "app.py"]
EOF

docker build -t myserver:v2 .

# Override at runtime
docker run -d -p 8081:9090 \
  -e PORT=9090 \
  -e APP_ENV=staging \
  --name myserver-staging \
  myserver:v2

curl http://localhost:8081 | jq .

# Inspect env vars
docker inspect myserver-staging --format='{{range .Config.Env}}{{.}}
{{end}}'

# NEVER hardcode secrets in image!
# Use: docker run -e SECRET_KEY=$(vault kv get ...) myserver
# Or:  --env-file .env  (but don't commit .env!)

docker rm -f myserver myserver-staging
```

---

## Part 5: Persistent Storage

```bash
# Containers are ephemeral — data in writable layer is lost on rm

# Demonstrate ephemeral storage
docker run --name demo alpine sh -c "echo 'important data' > /data/file.txt"
docker start demo
docker exec demo cat /data/file.txt
# File IS there while container exists

docker rm demo   # Remove container
docker run --name demo alpine cat /data/file.txt 2>&1 || echo "Data GONE!"

# Fix: use a volume
docker volume create app-data
docker run --name demo2 \
  -v app-data:/data \
  alpine sh -c "echo 'persistent data' > /data/file.txt"

docker rm demo2   # Remove container

docker run --rm -v app-data:/data alpine cat /data/file.txt
# Data PERSISTS! ✅

# Cleanup
docker volume rm app-data
cd ..
rm -rf docker-lab
```

---

## Part 6: Container Lifecycle

```bash
# Full lifecycle: create → start → pause → stop → start → remove

# Create without starting
docker create --name lifecycle-demo nginx:alpine
docker ps -a | grep lifecycle    # STATUS: Created

# Start it
docker start lifecycle-demo
docker ps | grep lifecycle       # STATUS: Up

# Pause (freeze processes, keep running)
docker pause lifecycle-demo
docker ps | grep lifecycle       # STATUS: Paused
curl http://localhost:80 || echo "Paused — no response"

# Unpause
docker unpause lifecycle-demo

# Stop (graceful: SIGTERM → 10s → SIGKILL)
docker stop lifecycle-demo

# Restart
docker start lifecycle-demo

# Remove (must be stopped first, or use -f to force)
docker stop lifecycle-demo && docker rm lifecycle-demo

# Or one command:
# docker rm -f lifecycle-demo
```

---

## What You Learned

- [x] Containers are isolated Linux processes
- [x] Images are layered read-only filesystems
- [x] Layers are shared across images (disk efficiency)
- [x] Environment variables for configuration (not hardcoded)
- [x] Volumes for persistent data
- [x] Container lifecycle: create/start/pause/stop/remove
