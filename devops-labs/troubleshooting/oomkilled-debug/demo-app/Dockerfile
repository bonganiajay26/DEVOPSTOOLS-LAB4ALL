# OOMKill Demo App — Dockerfile
# Multi-stage: test → production
# Build: docker build -t oom-demo:latest .
# Run:   docker run -p 8080:8080 --memory=256m oom-demo:latest

# ── Stage 1: Test ─────────────────────────────────────────────
FROM python:3.12-slim AS test

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt pytest

COPY app.py .
COPY tests/ tests/ 2>/dev/null || true

# Run basic smoke test
RUN python3 -c "
import app, time
# Verify app imports without error
print('Import test: OK')
# Verify leak list starts empty
assert len(app.LEAKED_CHUNKS) == 0
print('Initial state test: OK')
print('All tests passed')
"

# ── Stage 2: Production ───────────────────────────────────────
FROM python:3.12-slim AS production

# Security: non-root user
RUN useradd --uid 1001 --create-home appuser

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt && \
    pip cache purge

# Copy app
COPY --chown=appuser:appuser app.py .

USER appuser

EXPOSE 8080

# Health check
HEALTHCHECK --interval=10s --timeout=5s --start-period=10s --retries=3 \
    CMD python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')"

# Start gunicorn with 2 workers
# Note: with a memory leak, each worker leaks independently
CMD ["python3", "-m", "gunicorn", \
     "--bind", "0.0.0.0:8080", \
     "--workers", "1", \
     "--timeout", "60", \
     "--access-logfile", "-", \
     "--error-logfile", "-", \
     "app:app"]

# ── Usage ────────────────────────────────────────────────────
# # Build
# docker build --target production -t oom-demo:latest .
#
# # Run with 256MB limit (will OOMKill after ~25 leaks of 10MB)
# docker run -d \
#   --name oom-demo \
#   -p 8080:8080 \
#   --memory=256m \
#   --memory-swap=256m \
#   oom-demo:latest
#
# # Trigger the leak
# for i in $(seq 1 30); do
#   curl -s http://localhost:8080/leak?mb=10
#   curl -s http://localhost:8080/status | python3 -c "
#     import json, sys; d=json.load(sys.stdin)
#     print(f'RSS: {d[\"rss_mb\"]}MB | Leaked: {d[\"leaked_mb\"]}MB')"
#   sleep 1
# done
#
# # Watch it get killed
# docker stats oom-demo
# docker inspect oom-demo | jq '.[0].State.OOMKilled'
