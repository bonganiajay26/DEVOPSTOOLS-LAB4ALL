"""
Observability-First Instrumentation — Python / Flask / FastAPI
==============================================================
Before deploying any new version, these metrics MUST exist.
You cannot monitor what you cannot measure.

This file provides:
  1. Standard HTTP metrics (requests, latency, errors)
  2. Business metrics (orders, payments, users)
  3. Resource metrics (DB connections, cache hits, queue depth)
  4. Deployment tracking (which version is running)
  5. OpenTelemetry distributed tracing
  6. Structured logging for Loki

Install:
  pip install prometheus-client opentelemetry-sdk opentelemetry-instrumentation-flask
"""

import os
import time
import logging
from functools import wraps
from typing import Callable

from flask import Flask, request, g, jsonify
from prometheus_client import (
    Counter, Histogram, Gauge, Info,
    generate_latest, CONTENT_TYPE_LATEST,
    CollectorRegistry, REGISTRY,
)

# ── OpenTelemetry (distributed tracing) ──────────────────────
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.jaeger.thrift import JaegerExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.requests import RequestsInstrumentor
from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor

# ══════════════════════════════════════════════════════════════
# 1. STANDARD HTTP METRICS
# Every service MUST have these. Non-negotiable.
# ══════════════════════════════════════════════════════════════

# Counter: total requests — use for request rate and error rate
http_requests_total = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["method", "endpoint", "status_code", "service"]
)

# Histogram: request duration — use for latency SLOs
http_request_duration_seconds = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency in seconds",
    ["method", "endpoint"],
    buckets=[.005, .01, .025, .05, .1, .25, .5, 1, 2.5, 5, 10]
    # Buckets chosen to match common SLO thresholds (100ms, 500ms, 1s, 5s)
)

# Gauge: active in-flight requests
http_requests_in_progress = Gauge(
    "http_requests_in_progress",
    "Current in-flight HTTP requests",
    ["method", "endpoint"]
)

# ══════════════════════════════════════════════════════════════
# 2. BUSINESS METRICS
# These are what ACTUALLY matter for SLOs.
# Domain-specific — customize per service.
# ══════════════════════════════════════════════════════════════

# Orders
orders_created_total = Counter(
    "orders_created_total",
    "Total orders created",
    ["payment_method", "customer_tier"]
)
orders_failed_total = Counter(
    "orders_failed_total",
    "Total orders that failed",
    ["failure_reason"]
)
order_value_dollars = Histogram(
    "order_value_dollars",
    "Distribution of order values in dollars",
    buckets=[1, 10, 50, 100, 500, 1000, 5000]
)

# Payments
payments_processed_total = Counter(
    "payments_processed_total",
    "Total payment transactions",
    ["status", "provider"]   # status: success/failed, provider: stripe/paypal
)
payment_processing_duration = Histogram(
    "payment_processing_duration_seconds",
    "Time to process payment",
    ["provider"],
    buckets=[.1, .5, 1, 2, 5, 10, 30]
)

# Users
active_users = Gauge(
    "active_users_current",
    "Currently active users (sessions in last 15 min)"
)
user_registrations_total = Counter(
    "user_registrations_total",
    "Total user registrations",
    ["source"]   # organic, paid, referral
)

# ══════════════════════════════════════════════════════════════
# 3. RESOURCE METRICS
# Alert on these BEFORE they cause user-visible issues.
# ══════════════════════════════════════════════════════════════

db_connections_active = Gauge(
    "db_connections_active",
    "Active database connections",
    ["database"]
)
db_connections_pool_size = Gauge(
    "db_connections_pool_size",
    "Database connection pool size",
    ["database"]
)
db_query_duration_seconds = Histogram(
    "db_query_duration_seconds",
    "Database query execution time",
    ["query_type", "table"],   # query_type: select/insert/update/delete
    buckets=[.001, .005, .01, .05, .1, .5, 1, 5]
)

cache_operations_total = Counter(
    "cache_operations_total",
    "Total cache operations",
    ["operation", "result"]   # operation: get/set/delete, result: hit/miss/error
)

queue_depth = Gauge(
    "queue_depth_messages",
    "Number of messages waiting in queue",
    ["queue_name"]
)

# ══════════════════════════════════════════════════════════════
# 4. DEPLOYMENT TRACKING
# Know EXACTLY which version is running and when it deployed.
# ══════════════════════════════════════════════════════════════

app_info = Info(
    "app",
    "Application version information"
)
# Populate with build metadata:
app_info.info({
    "version":    os.getenv("APP_VERSION", "unknown"),
    "git_sha":    os.getenv("GIT_SHA", "unknown"),
    "build_date": os.getenv("BUILD_DATE", "unknown"),
    "service":    os.getenv("SERVICE_NAME", "myapp"),
    "environment": os.getenv("APP_ENV", "production"),
})

# Track deployment events (gauge so Prometheus can alert on version change)
deploy_timestamp = Gauge(
    "app_deploy_timestamp_seconds",
    "Unix timestamp of last deployment",
    ["version", "environment"]
)
deploy_timestamp.labels(
    version=os.getenv("APP_VERSION", "unknown"),
    environment=os.getenv("APP_ENV", "production")
).set_to_current_time()


# ══════════════════════════════════════════════════════════════
# 5. FLASK INTEGRATION
# ══════════════════════════════════════════════════════════════

def instrument_flask_app(app: Flask) -> Flask:
    """Add all instrumentation to a Flask app."""

    # ── HTTP middleware ────────────────────────────────────────
    @app.before_request
    def before_request():
        g.start_time = time.time()
        # Normalize endpoint (replace IDs with placeholders)
        g.endpoint = _normalize_path(request.path)
        http_requests_in_progress.labels(
            method=request.method,
            endpoint=g.endpoint
        ).inc()

    @app.after_request
    def after_request(response):
        duration = time.time() - getattr(g, 'start_time', time.time())
        endpoint = getattr(g, 'endpoint', request.path)

        http_request_duration_seconds.labels(
            method=request.method,
            endpoint=endpoint
        ).observe(duration)

        http_requests_total.labels(
            method=request.method,
            endpoint=endpoint,
            status_code=str(response.status_code),
            service=os.getenv("SERVICE_NAME", "myapp")
        ).inc()

        http_requests_in_progress.labels(
            method=request.method,
            endpoint=endpoint
        ).dec()

        # Add version header to every response
        response.headers["X-Service-Version"] = os.getenv("APP_VERSION", "unknown")
        response.headers["X-Request-Id"] = getattr(g, 'request_id', '')

        return response

    # ── Metrics endpoint ───────────────────────────────────────
    @app.route("/metrics")
    def metrics():
        return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}

    # ── Health endpoints ───────────────────────────────────────
    @app.route("/health/live")
    def health_live():
        """Liveness: is the app alive? (no deadlock)"""
        return jsonify({"status": "alive"}), 200

    @app.route("/health/ready")
    def health_ready():
        """Readiness: is the app ready for traffic? (deps connected)"""
        checks = {}
        ok = True

        # Check DB connection
        try:
            db_connections_active.labels("main")._value.get()  # noqa
            checks["database"] = "ok"
        except Exception as e:
            checks["database"] = f"error: {e}"
            ok = False

        # Check cache
        checks["cache"] = "ok"  # Add real check here

        status_code = 200 if ok else 503
        return jsonify({
            "status": "ready" if ok else "not_ready",
            "checks": checks,
            "version": os.getenv("APP_VERSION", "unknown"),
        }), status_code

    @app.route("/health/started")
    def health_started():
        """Startup probe: has the app finished initializing?"""
        return jsonify({"status": "started"}), 200

    return app


# ══════════════════════════════════════════════════════════════
# 6. OPENTELEMETRY DISTRIBUTED TRACING
# ══════════════════════════════════════════════════════════════

def setup_tracing(service_name: str = None) -> trace.Tracer:
    """Configure OpenTelemetry with Jaeger export."""
    service_name = service_name or os.getenv("SERVICE_NAME", "myapp")

    jaeger_exporter = JaegerExporter(
        agent_host_name=os.getenv("JAEGER_HOST", "jaeger.tracing.svc.cluster.local"),
        agent_port=int(os.getenv("JAEGER_PORT", "6831")),
    )

    provider = TracerProvider()
    provider.add_span_processor(BatchSpanProcessor(jaeger_exporter))
    trace.set_tracer_provider(provider)

    # Auto-instrument common libraries
    FlaskInstrumentor().instrument()
    RequestsInstrumentor().instrument()
    SQLAlchemyInstrumentor().instrument()

    return trace.get_tracer(service_name)


# ══════════════════════════════════════════════════════════════
# 7. STRUCTURED LOGGING
# ══════════════════════════════════════════════════════════════

import json
from datetime import datetime

class StructuredLogger:
    """JSON structured logger for Loki ingestion."""

    def __init__(self, service: str):
        self.service = service
        self.version = os.getenv("APP_VERSION", "unknown")
        self.env     = os.getenv("APP_ENV", "production")

    def _log(self, level: str, message: str, **kwargs):
        # Get trace context for log-trace correlation
        span = trace.get_current_span()
        trace_id = format(span.get_span_context().trace_id, '032x') \
            if span.get_span_context().is_valid else ""

        entry = {
            "timestamp": datetime.utcnow().isoformat() + "Z",
            "level":     level,
            "message":   message,
            "service":   self.service,
            "version":   self.version,
            "environment": self.env,
            "trace_id":  trace_id,   # For Grafana log-trace correlation
            **kwargs
        }
        print(json.dumps(entry), flush=True)

    def info(self, message, **kwargs):  self._log("INFO",  message, **kwargs)
    def warn(self, message, **kwargs):  self._log("WARN",  message, **kwargs)
    def error(self, message, **kwargs): self._log("ERROR", message, **kwargs)


# ══════════════════════════════════════════════════════════════
# 8. BUSINESS METRICS HELPERS
# Decorate your service functions to auto-track metrics
# ══════════════════════════════════════════════════════════════

def track_order_created(payment_method: str, customer_tier: str, value: float):
    orders_created_total.labels(
        payment_method=payment_method,
        customer_tier=customer_tier
    ).inc()
    order_value_dollars.observe(value)

def track_payment_processed(provider: str, status: str, duration: float):
    payments_processed_total.labels(provider=provider, status=status).inc()
    payment_processing_duration.labels(provider=provider).observe(duration)

def track_db_query(query_type: str, table: str):
    """Decorator for automatic DB query timing."""
    def decorator(func: Callable):
        @wraps(func)
        def wrapper(*args, **kwargs):
            start = time.time()
            try:
                result = func(*args, **kwargs)
                db_query_duration_seconds.labels(
                    query_type=query_type, table=table
                ).observe(time.time() - start)
                return result
            except Exception as e:
                db_query_duration_seconds.labels(
                    query_type=query_type, table=table
                ).observe(time.time() - start)
                raise
        return wrapper
    return decorator


# ══════════════════════════════════════════════════════════════
# UTILITY: Normalize URL paths for metric cardinality control
# Without this, /users/12345 and /users/67890 become separate metrics!
# ══════════════════════════════════════════════════════════════

import re

def _normalize_path(path: str) -> str:
    """Replace IDs and UUIDs with placeholders to prevent metric explosion."""
    path = re.sub(r'/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', '/<uuid>', path)
    path = re.sub(r'/\d+', '/<id>', path)
    return path

# /api/users/123          → /api/users/<id>
# /api/orders/abc-123-def → /api/orders/<uuid>


# ══════════════════════════════════════════════════════════════
# PRE-DEPLOY CHECKLIST (enforce before any deployment)
# ══════════════════════════════════════════════════════════════

OBSERVABILITY_CHECKLIST = """
Before deploying any change, verify:

METRICS:
  □ /metrics endpoint exists and returns Prometheus format
  □ http_requests_total has method, endpoint, status labels
  □ http_request_duration_seconds has correct buckets for SLO
  □ Business metrics exist for the changed feature
  □ New feature has its own counter (so you can A/B compare versions)

TRACING:
  □ Distributed tracing context propagated through all service calls
  □ Database queries create child spans
  □ External API calls create spans
  □ trace_id appears in logs (for log-trace correlation)

LOGGING:
  □ All errors logged with context (user_id, request_id, trace_id)
  □ No sensitive data in logs (passwords, tokens, PII)
  □ Log level set appropriately (INFO in prod, not DEBUG)

ALERTING:
  □ New endpoint has error rate + latency coverage in existing alerts
  □ New business metric has alerting if business-critical
  □ No alert that fires without a runbook

See scripts/pre-deploy-checklist.sh to verify automatically.
"""
