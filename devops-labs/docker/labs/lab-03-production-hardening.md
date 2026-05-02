# Lab 03: Docker Production Hardening

**Difficulty**: Advanced | **Time**: 60 minutes  
**Goal**: Take a naive container and harden it for production: security, size, scanning.

---

## Part 1: Start with a "Bad" Dockerfile — Measure the Problems

```bash
mkdir hardening-lab && cd hardening-lab

cat > app.py << 'EOF'
from flask import Flask, jsonify
import os

app = Flask(__name__)

@app.route("/")
def index():
    return jsonify({"user": os.popen("whoami").read().strip()})

@app.route("/health")
def health():
    return jsonify({"status": "ok"})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
EOF

cat > requirements.txt << 'EOF'
flask==3.0.0
gunicorn==21.2.0
EOF

# ❌ BAD Dockerfile
cat > Dockerfile.bad << 'EOF'
FROM python:3.12
WORKDIR /app
COPY . .
RUN pip install -r requirements.txt
EXPOSE 8080
CMD python app.py
EOF

# Build and measure
docker build -t myapp:bad -f Dockerfile.bad .
echo "BAD image size:"
docker image inspect myapp:bad | jq '.[0].Size' | numfmt --to=iec

# Run as root
docker run -d -p 8080:8080 --name bad-app myapp:bad
curl http://localhost:8080/   # Shows: root 😱
docker rm -f bad-app

# Scan for vulnerabilities
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy image myapp:bad | tail -20
```

---

## Part 2: Harden Step by Step

### Step 1: Pin base image version

```dockerfile
# Change: FROM python:3.12  → FROM python:3.12.2-slim
# Smaller base, specific version (reproducible builds)
```

### Step 2: Add .dockerignore

```bash
cat > .dockerignore << 'EOF'
.git/
.env*
__pycache__/
*.pyc
tests/
*.md
Dockerfile*
docker-compose*
.venv/
EOF
```

### Step 3: Non-root user + read-only filesystem

```bash
cat > Dockerfile.hardened << 'EOF'
FROM python:3.12.2-slim AS base

# Install security updates in same layer
RUN apt-get update && apt-get upgrade -y && \
    apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/* && \
    # Create non-root user
    groupadd -r appuser && \
    useradd -r -g appuser -s /sbin/nologin appuser

WORKDIR /app

FROM base AS builder
COPY requirements.txt .
# Install to user directory
RUN pip install --user --no-cache-dir -r requirements.txt

FROM base AS production
# Copy only installed packages
COPY --from=builder /root/.local /home/appuser/.local
# Copy app
COPY --chown=appuser:appuser app.py .

# Switch to non-root
USER appuser

# Read-only filesystem hint (docker run --read-only needs tmpfs for /tmp)
VOLUME ["/tmp"]

EXPOSE 8080

# Security labels
LABEL security.scan-date="2024-01-01"
LABEL security.hardened="true"

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

CMD ["python", "-m", "gunicorn", \
     "--bind", "0.0.0.0:8080", \
     "--workers", "2", \
     "--timeout", "30", \
     "--access-logfile", "-", \
     "--error-logfile", "-", \
     "app:app"]
EOF

# Build hardened version
docker build -t myapp:hardened -f Dockerfile.hardened .

echo "BAD size:"
docker image inspect myapp:bad | jq '.[0].Size' | numfmt --to=iec
echo "HARDENED size:"
docker image inspect myapp:hardened | jq '.[0].Size' | numfmt --to=iec
```

---

## Part 3: Runtime Security Controls

```bash
# Run with maximum security
docker run -d \
  --name hardened-app \
  --user 1000:1000 \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=100m \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --security-opt seccomp=default.json \
  --memory=512m \
  --memory-swap=512m \
  --cpus=0.5 \
  --pids-limit=100 \
  -p 8080:8080 \
  myapp:hardened

# Test it works
curl http://localhost:8080/health
curl http://localhost:8080/      # Still shows non-root user!

# Verify security
echo "Running as user:"
docker exec hardened-app whoami 2>/dev/null || echo "exec blocked (no shell = good!)"

echo ""
echo "Container capabilities:"
docker inspect hardened-app --format='{{.HostConfig.CapDrop}}'

echo ""
echo "Readonly rootfs:"
docker exec hardened-app touch /test 2>&1 || echo "✅ Cannot write to root filesystem"
docker exec hardened-app touch /tmp/test && echo "✅ Can write to /tmp (tmpfs)"

docker rm -f hardened-app
```

---

## Part 4: Image Scanning with Trivy

```bash
# Install trivy (macOS)
# brew install trivy
# Or use Docker:
TRIVY="docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasec/trivy"

echo "=== Scanning BAD image ==="
$TRIVY image myapp:bad

echo ""
echo "=== Scanning HARDENED image ==="
$TRIVY image myapp:hardened

echo ""
echo "=== Summary ==="
BAD_CRITICAL=$($TRIVY image myapp:bad --severity CRITICAL 2>/dev/null | grep -c "CRITICAL" || echo "?")
HARD_CRITICAL=$($TRIVY image myapp:hardened --severity CRITICAL 2>/dev/null | grep -c "CRITICAL" || echo "?")
echo "BAD image CRITICAL CVEs:     $BAD_CRITICAL"
echo "HARDENED image CRITICAL CVEs: $HARD_CRITICAL"
```

---

## Part 5: SBOM and Provenance

```bash
# Generate Software Bill of Materials
docker sbom myapp:hardened

# Or with syft
# syft myapp:hardened -o spdx-json > sbom.json
# cat sbom.json | jq '.packages | length'
# echo "Packages in image: $(cat sbom.json | jq '.packages | length')"

# Sign the image (requires cosign)
# cosign sign --key cosign.key ghcr.io/myorg/myapp:hardened
# cosign verify --key cosign.pub ghcr.io/myorg/myapp:hardened
```

---

## Part 6: Before/After Comparison

```bash
echo "=== Security Hardening Results ==="
echo ""

printf "%-30s %-20s %-20s\n" "Metric" "BAD" "HARDENED"
printf "%-30s %-20s %-20s\n" "---" "---" "---"

BAD_SIZE=$(docker image inspect myapp:bad | jq '.[0].Size' | numfmt --to=iec)
HARD_SIZE=$(docker image inspect myapp:hardened | jq '.[0].Size' | numfmt --to=iec)
printf "%-30s %-20s %-20s\n" "Image Size" "$BAD_SIZE" "$HARD_SIZE"

BAD_LAYERS=$(docker history myapp:bad | wc -l)
HARD_LAYERS=$(docker history myapp:hardened | wc -l)
printf "%-30s %-20s %-20s\n" "Layers" "$BAD_LAYERS" "$HARD_LAYERS"

printf "%-30s %-20s %-20s\n" "Runs as root" "YES ❌" "NO ✅"
printf "%-30s %-20s %-20s\n" "Read-only filesystem" "NO ❌" "YES ✅"
printf "%-30s %-20s %-20s\n" "Has health check" "NO ❌" "YES ✅"
printf "%-30s %-20s %-20s\n" "Version pinned" "NO ❌" "YES ✅"
printf "%-30s %-20s %-20s\n" "Multi-stage build" "NO ❌" "YES ✅"
```

---

## Cleanup

```bash
docker rmi myapp:bad myapp:hardened
cd ..
rm -rf hardening-lab
```

## What You Learned

- [x] Why running as root is dangerous
- [x] Multi-stage builds for minimal runtime images  
- [x] `--read-only` + `--tmpfs` for immutable containers
- [x] `--cap-drop=ALL` to remove Linux capabilities
- [x] CVE scanning with Trivy
- [x] SBOM generation for compliance
