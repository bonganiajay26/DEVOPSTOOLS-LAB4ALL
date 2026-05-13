# Datadog APM — Python instrumentation
# Place at the very top of your application entry point

from ddtrace import patch_all, tracer

# Auto-instrument all supported libraries (flask, requests, psycopg2, redis, etc.)
patch_all()

# Optional: custom span example
def process_order(order_id: str) -> dict:
    with tracer.trace("order.process", service="payment-service", resource=order_id) as span:
        span.set_tag("order.id", order_id)
        span.set_tag("env", "production")
        # ... business logic ...
        result = {"status": "ok"}
        return result


# ── CLI alternative (zero code changes) ──────────────────────────
# DD_SERVICE=my-api \
# DD_ENV=production \
# DD_VERSION=1.2.3 \
# DD_LOGS_INJECTION=true \
# ddtrace-run python app.py
