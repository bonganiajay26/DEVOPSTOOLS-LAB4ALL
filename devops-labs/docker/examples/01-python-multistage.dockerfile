# Production Python Multi-stage Dockerfile
# Run: docker build -t myapi:prod --target production .
# Dev:  docker build -t myapi:dev  --target development .

# ── Stage 1: Base ────────────────────────────────────────────
FROM python:3.12-slim AS base
# Pin OS packages and clean up in same layer (reduce size)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# ── Stage 2: Dependencies ────────────────────────────────────
FROM base AS dependencies
COPY requirements.txt requirements-dev.txt ./
# Install prod deps to /install (separate from system Python)
RUN pip install --prefix=/install -r requirements.txt

# ── Stage 3: Development ─────────────────────────────────────
FROM dependencies AS development
# Install dev tools on top
RUN pip install --prefix=/install -r requirements-dev.txt
COPY . .
ENV PYTHONPATH=/install/lib/python3.12/site-packages
CMD ["python", "-m", "uvicorn", "src.main:app", "--reload", "--host", "0.0.0.0", "--port", "8000"]

# ── Stage 4: Test ─────────────────────────────────────────────
FROM development AS test
RUN python -m pytest tests/ -v --cov=src --cov-report=term

# ── Stage 5: Production ───────────────────────────────────────
FROM base AS production
# Security: non-root user
RUN groupadd -r appuser && useradd -r -g appuser -s /sbin/nologin appuser

# Copy only the installed packages from dependencies stage
COPY --from=dependencies /install /usr/local

# Copy application source
COPY --chown=appuser:appuser src/ ./src/

# Switch to non-root
USER appuser

EXPOSE 8000

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')" || exit 1

# Metadata labels
LABEL org.opencontainers.image.title="My API"
LABEL org.opencontainers.image.version="1.0.0"
LABEL org.opencontainers.image.description="Production API service"
LABEL org.opencontainers.image.source="https://github.com/myorg/myapi"

CMD ["python", "-m", "uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "4"]
