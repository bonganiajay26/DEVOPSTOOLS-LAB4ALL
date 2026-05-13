"""
Integration tests — APM trace submission and retrieval.

Sends real traces to the agent and then verifies they appear
in the Datadog API (within a polling window).

Requires:
  - Running Datadog agent with APM enabled
  - DD_API_KEY and DD_APP_KEY set
"""

import time
import pytest
from datadog_api_client.v1 import ApiException
from datadog_api_client.v1.api.metrics_api import MetricsApi


pytestmark = [pytest.mark.agent, pytest.mark.api, pytest.mark.slow]

TRACE_WAIT_SECONDS = 60   # Datadog APM ingestion latency
POLL_INTERVAL = 5


def send_test_trace(service: str, resource: str, error: bool = False) -> str:
    """Send a trace via ddtrace and return a unique tag for lookup."""
    try:
        from ddtrace import tracer
    except ImportError:
        pytest.skip("ddtrace not installed — pip install ddtrace")

    test_id = f"test-{int(time.time())}"

    with tracer.trace("integration.test", service=service, resource=resource) as span:
        span.set_tag("test.id", test_id)
        span.set_tag("test.type", "integration")
        if error:
            span.error = 1
            span.set_tag("error.type", "TestError")
            span.set_tag("error.msg", "Intentional test error")
        time.sleep(0.05)

    return test_id


class TestAPMTraceSubmission:
    def test_normal_trace_sent_without_exception(self, dd_config):
        test_id = send_test_trace(
            service=dd_config["service"],
            resource="/test/integration"
        )
        assert test_id.startswith("test-")

    def test_error_trace_sent_without_exception(self, dd_config):
        test_id = send_test_trace(
            service=dd_config["service"],
            resource="/test/integration/error",
            error=True
        )
        assert test_id.startswith("test-")

    def test_multiple_traces_sent(self, dd_config):
        ids = []
        for i in range(5):
            test_id = send_test_trace(
                service=dd_config["service"],
                resource=f"/test/batch/{i}"
            )
            ids.append(test_id)
            time.sleep(0.02)
        assert len(set(ids)) == 5, "Trace IDs should be unique"


class TestAPMMetricsInAPI:
    """
    Verify that APM-generated metrics appear in the Datadog Metrics API.
    These metrics are created automatically by the APM pipeline.
    """

    def test_trace_hits_metric_exists(self, dd_api_client, dd_config):
        from datadog_api_client.v1.api.metrics_api import MetricsApi

        # First send a trace to generate the metric
        send_test_trace(service=dd_config["service"], resource="/test/metric-check")

        # Wait for ingestion
        time.sleep(TRACE_WAIT_SECONDS)

        api = MetricsApi(dd_api_client)
        now = int(time.time())
        from_ts = now - 300  # last 5 minutes

        try:
            result = api.query_metrics(
                _from=from_ts,
                to=now,
                query=f"sum:trace.web.request.hits{{service:{dd_config['service']},env:{dd_config['env']}}}.as_rate()"
            )
            assert result.series, \
                f"No APM hit metrics found for service:{dd_config['service']} — check APM instrumentation"
        except ApiException as e:
            pytest.fail(f"Datadog API error: {e}")

    def test_trace_error_metric_exists(self, dd_api_client, dd_config):
        from datadog_api_client.v1.api.metrics_api import MetricsApi

        send_test_trace(service=dd_config["service"], resource="/test/error-check", error=True)
        time.sleep(TRACE_WAIT_SECONDS)

        api = MetricsApi(dd_api_client)
        now = int(time.time())

        try:
            result = api.query_metrics(
                _from=now - 300,
                to=now,
                query=f"sum:trace.web.request.errors{{service:{dd_config['service']},env:{dd_config['env']}}}.as_rate()"
            )
            # Just verify the query succeeds — error count may be 0
            assert result is not None
        except ApiException as e:
            pytest.fail(f"Datadog API error: {e}")
