#!/usr/bin/env python3
"""Send a test APM trace to verify the agent is receiving traces."""

import time
import sys

try:
    from ddtrace import tracer
except ImportError:
    print("ERROR: ddtrace not installed — run: pip install ddtrace")
    sys.exit(1)

print("Sending test trace to Datadog agent...")

with tracer.trace("validation.test", service="validation-script", resource="/validate") as span:
    span.set_tag("env", "production")
    span.set_tag("validation", "true")
    span.set_tag("test.timestamp", time.time())
    time.sleep(0.1)   # simulate work

print("Test trace sent.")
print("Check APM → Traces → filter by service:validation-script")
print("Should appear within 30 seconds.")
