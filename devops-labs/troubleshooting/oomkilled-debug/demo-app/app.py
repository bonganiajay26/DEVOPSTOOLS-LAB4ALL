"""
OOMKill Demo Application
========================
A production-realistic Flask app with intentional memory leak endpoints
for practicing OOMKill debugging methodology.

Endpoints:
  GET /health           → liveness/readiness probe
  GET /metrics          → Prometheus metrics (process + custom)
  GET /status           → current memory stats (JSON)
  POST /leak?mb=50      → allocate N MB and HOLD it (never freed)
  POST /spike?mb=200    → allocate N MB then release (spike pattern)
  POST /free            → release all leaked memory
  GET /work?items=1000  → simulate real processing (builds a dict, holds briefly)

Usage:
  docker build -t oom-demo .
  docker run -p 8080:8080 --memory=256m oom-demo
  curl http://localhost:8080/leak?mb=30   # leak 30MB at a time
  curl http://localhost:8080/status       # see total leaked
  watch -n1 'curl -s http://localhost:8080/metrics | grep demo'
"""

import gc
import os
import resource
import threading
import time
from datetime import datetime
from functools import wraps
from urllib.parse import parse_qs, urlparse

from flask import Flask, jsonify, request
from prometheus_client import (
    Counter, Gauge, Histogram, generate_latest, CONTENT_TYPE_LATEST
)

app = Flask(__name__)

# ── Prometheus metrics ────────────────────────────────────────
REQUEST_COUNT   = Counter("http_requests_total",
                          "Total HTTP requests", ["method", "endpoint", "status"])
REQUEST_LATENCY = Histogram("http_request_duration_seconds",
                             "Request latency", ["endpoint"])
LEAKED_BYTES    = Gauge("demo_leaked_bytes_total",
                         "Total bytes intentionally leaked (never freed)")
PROCESS_MEMORY  = Gauge("process_resident_memory_bytes",
                         "Current RSS memory in bytes")
LEAK_CHUNKS     = Gauge("demo_leak_chunks_total",
                         "Number of leaked memory chunks")

# ── Application state ─────────────────────────────────────────
LEAKED_CHUNKS   = []         # Never freed — simulates a leak
SPIKES          = []         # Released after spike
START_TIME      = time.time()

def update_memory_metrics():
    """Background thread: update Prometheus memory metrics every 5s."""
    while True:
        try:
            usage = resource.getrusage(resource.RUSAGE_SELF)
            PROCESS_MEMORY.set(usage.ru_maxrss * 1024)  # KB → bytes (Linux)
            LEAKED_BYTES.set(sum(len(c) for c in LEAKED_CHUNKS))
            LEAK_CHUNKS.set(len(LEAKED_CHUNKS))
        except Exception:
            pass
        time.sleep(5)

threading.Thread(target=update_memory_metrics, daemon=True).start()

# ── Middleware ────────────────────────────────────────────────
def track_metrics(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        start = time.time()
        response = f(*args, **kwargs)
        duration = time.time() - start
        status = response[1] if isinstance(response, tuple) else 200
        REQUEST_COUNT.labels(request.method, request.path, str(status)).inc()
        REQUEST_LATENCY.labels(request.path).observe(duration)
        return response
    return decorated

# ── Routes ────────────────────────────────────────────────────

@app.route("/health")
@track_metrics
def health():
    return jsonify({"status": "healthy", "uptime_seconds": int(time.time() - START_TIME)}), 200


@app.route("/metrics")
def metrics():
    """Prometheus scrape endpoint."""
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}


@app.route("/status")
@track_metrics
def status():
    """Current memory status — useful for monitoring."""
    usage = resource.getrusage(resource.RUSAGE_SELF)
    rss_bytes = usage.ru_maxrss * 1024   # KB → bytes on Linux

    leaked_total = sum(len(c) for c in LEAKED_CHUNKS)

    return jsonify({
        "rss_mb":           round(rss_bytes / 1024 / 1024, 1),
        "leaked_mb":        round(leaked_total / 1024 / 1024, 1),
        "leaked_chunks":    len(LEAKED_CHUNKS),
        "uptime_seconds":   int(time.time() - START_TIME),
        "timestamp":        datetime.utcnow().isoformat(),
    }), 200


@app.route("/leak")
@track_metrics
def leak():
    """
    Allocate N MB and HOLD it — simulates a memory leak.
    The data is never freed, causing steady memory growth.

    Example: GET /leak?mb=50
    """
    mb = int(request.args.get("mb", 10))
    mb = min(mb, 500)   # Cap at 500MB per request for safety

    # Allocate bytes and append to leak list (never freed)
    chunk = bytearray(mb * 1024 * 1024)
    LEAKED_CHUNKS.append(chunk)

    total_leaked_mb = sum(len(c) for c in LEAKED_CHUNKS) / 1024 / 1024

    print(f"[LEAK] +{mb}MB | Total leaked: {total_leaked_mb:.1f}MB | "
          f"Chunks: {len(LEAKED_CHUNKS)}", flush=True)

    return jsonify({
        "action":            "leak",
        "allocated_mb":      mb,
        "total_leaked_mb":   round(total_leaked_mb, 1),
        "chunks":            len(LEAKED_CHUNKS),
        "warning":           "This memory will never be freed!",
    }), 200


@app.route("/spike")
@track_metrics
def spike():
    """
    Allocate N MB briefly, then release — simulates a traffic spike.
    This shows a different pattern from a leak (spikes, not gradual growth).

    Example: GET /spike?mb=200&hold_ms=2000
    """
    mb      = int(request.args.get("mb", 100))
    hold_ms = int(request.args.get("hold_ms", 1000))
    mb      = min(mb, 1000)

    print(f"[SPIKE] Allocating {mb}MB for {hold_ms}ms...", flush=True)

    spike_data = bytearray(mb * 1024 * 1024)
    SPIKES.append(spike_data)
    time.sleep(hold_ms / 1000)

    SPIKES.remove(spike_data)
    del spike_data
    gc.collect()

    print(f"[SPIKE] Released {mb}MB", flush=True)

    return jsonify({
        "action":     "spike",
        "spike_mb":   mb,
        "held_ms":    hold_ms,
        "released":   True,
    }), 200


@app.route("/free")
@track_metrics
def free():
    """Release all leaked memory and force GC."""
    freed_mb = sum(len(c) for c in LEAKED_CHUNKS) / 1024 / 1024
    freed_chunks = len(LEAKED_CHUNKS)

    LEAKED_CHUNKS.clear()
    gc.collect()

    print(f"[FREE] Released {freed_mb:.1f}MB ({freed_chunks} chunks)", flush=True)

    return jsonify({
        "action":      "free",
        "freed_mb":    round(freed_mb, 1),
        "freed_chunks": freed_chunks,
        "status":       "all leaked memory freed",
    }), 200


@app.route("/work")
@track_metrics
def work():
    """
    Simulate real work — builds a dict with N items.
    Memory usage is proportional but gets GC'd afterward.

    Example: GET /work?items=100000
    """
    items = int(request.args.get("items", 10000))
    items = min(items, 1_000_000)

    # Build a realistically-sized data structure
    data = {f"key_{i}": f"value_{i}_" + "x" * 100 for i in range(items)}
    result = len(data)
    del data
    gc.collect()

    return jsonify({
        "action":     "work",
        "items":      result,
        "status":     "completed and released",
    }), 200


@app.route("/")
def index():
    return jsonify({
        "app":        "OOMKill Demo",
        "endpoints": {
            "/health":        "GET  - Health check",
            "/metrics":       "GET  - Prometheus metrics",
            "/status":        "GET  - Current memory stats",
            "/leak?mb=50":    "GET  - Leak 50MB (never freed)",
            "/spike?mb=200":  "GET  - Spike 200MB then release",
            "/free":          "GET  - Release all leaked memory",
            "/work?items=1k": "GET  - Simulate real work (GC'd after)",
        },
        "quick_start": [
            "# Leak memory gradually (10MB at a time):",
            "for i in $(seq 1 20); do curl -s localhost:8080/leak?mb=10; sleep 2; done",
            "",
            "# Watch memory grow:",
            "watch -n2 'curl -s localhost:8080/status | python3 -m json.tool'",
        ]
    }), 200


if __name__ == "__main__":
    port = int(os.getenv("PORT", 8080))
    print(f"OOMKill Demo App starting on port {port}", flush=True)
    print("Endpoints: /leak /spike /free /status /metrics", flush=True)
    app.run(host="0.0.0.0", port=port, threaded=True)
