"""
Integration tests — Custom metrics via DogStatsD.

Sends metrics through the agent's DogStatsD socket and then validates
they appear in the Datadog Metrics API within an ingestion window.

Requires:
  - Running Datadog agent with DogStatsD enabled (port 8125 UDP)
  - DD_API_KEY and DD_APP_KEY set
"""

import socket
import time
import pytest


pytestmark = [pytest.mark.agent, pytest.mark.api, pytest.mark.slow]

METRICS_WAIT_SECONDS = 60
METRIC_PREFIX = "quantum.test"


def send_statsd(host: str, port: int, payload: str):
    """Send a raw DogStatsD payload over UDP."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.sendto(payload.encode(), (host, port))
    finally:
        sock.close()


def statsd_metric(name: str, value: float, type_: str, tags: list[str]) -> str:
    tag_str = ",".join(tags)
    return f"{name}:{value}|{type_}|#{tag_str}"


class TestDogStatsDSubmission:
    def test_counter_sent(self, dd_config):
        payload = statsd_metric(
            f"{METRIC_PREFIX}.counter",
            1,
            "c",
            [f"env:{dd_config['env']}", f"service:{dd_config['service']}", "test:true"]
        )
        # UDP is fire-and-forget — success = no OS error
        send_statsd(dd_config["agent_host"], dd_config["agent_statsd_port"], payload)

    def test_gauge_sent(self, dd_config):
        payload = statsd_metric(
            f"{METRIC_PREFIX}.gauge",
            42.5,
            "g",
            [f"env:{dd_config['env']}", f"service:{dd_config['service']}", "test:true"]
        )
        send_statsd(dd_config["agent_host"], dd_config["agent_statsd_port"], payload)

    def test_histogram_sent(self, dd_config):
        payload = statsd_metric(
            f"{METRIC_PREFIX}.histogram",
            0.145,
            "h",
            [f"env:{dd_config['env']}", f"service:{dd_config['service']}", "test:true"]
        )
        send_statsd(dd_config["agent_host"], dd_config["agent_statsd_port"], payload)

    def test_distribution_sent(self, dd_config):
        payload = statsd_metric(
            f"{METRIC_PREFIX}.distribution",
            0.250,
            "d",
            [f"env:{dd_config['env']}", f"service:{dd_config['service']}", "test:true"]
        )
        send_statsd(dd_config["agent_host"], dd_config["agent_statsd_port"], payload)

    def test_batch_metrics_sent(self, dd_config):
        """DogStatsD supports newline-separated batch payloads."""
        payloads = "\n".join([
            statsd_metric(f"{METRIC_PREFIX}.batch.a", 1, "c", [f"env:{dd_config['env']}"]),
            statsd_metric(f"{METRIC_PREFIX}.batch.b", 2, "c", [f"env:{dd_config['env']}"]),
            statsd_metric(f"{METRIC_PREFIX}.batch.c", 3, "g", [f"env:{dd_config['env']}"]),
        ])
        send_statsd(dd_config["agent_host"], dd_config["agent_statsd_port"], payloads)


class TestMetricsInAPI:
    """
    Validate that custom metrics sent via DogStatsD appear in the Datadog API.
    """

    def test_custom_counter_appears_in_api(self, dd_api_client, dd_config):
        from datadog_api_client.v1.api.metrics_api import MetricsApi

        # Send metric
        test_value = 99
        payload = statsd_metric(
            f"{METRIC_PREFIX}.api_check",
            test_value,
            "g",
            [f"env:{dd_config['env']}", f"service:{dd_config['service']}", "test:api-check"]
        )
        send_statsd(dd_config["agent_host"], dd_config["agent_statsd_port"], payload)

        # Wait for ingestion
        time.sleep(METRICS_WAIT_SECONDS)

        api = MetricsApi(dd_api_client)
        now = int(time.time())

        result = api.query_metrics(
            _from=now - 300,
            to=now,
            query=f"avg:{METRIC_PREFIX}.api_check{{env:{dd_config['env']},service:{dd_config['service']}}}"
        )
        assert result.series, \
            f"Custom metric '{METRIC_PREFIX}.api_check' not found in API after {METRICS_WAIT_SECONDS}s"

    def test_system_metrics_available(self, dd_api_client, dd_config):
        """System metrics (CPU, memory) should always be present if agent is running."""
        from datadog_api_client.v1.api.metrics_api import MetricsApi

        api = MetricsApi(dd_api_client)
        now = int(time.time())

        for metric in ["system.cpu.user", "system.mem.used", "system.disk.in_use"]:
            result = api.query_metrics(
                _from=now - 300,
                to=now,
                query=f"avg:{metric}{{env:{dd_config['env']}}}"
            )
            assert result.series, \
                f"System metric '{metric}' not found — is the Datadog agent running?"


class TestMetricNaming:
    """Unit-style checks for metric naming conventions."""

    VALID_METRIC_PATTERN = __import__("re").compile(r"^[a-z][a-z0-9_.]*[a-z0-9]$")
    MAX_METRIC_NAME_LENGTH = 200

    @pytest.mark.parametrize("name", [
        "quantum.orders.created",
        "quantum.api.latency",
        "quantum.queue.depth",
        "quantum.cache.hit_rate",
    ])
    def test_valid_metric_names(self, name):
        assert self.VALID_METRIC_PATTERN.match(name), f"Invalid metric name: {name}"

    @pytest.mark.parametrize("name", [
        "quantum.Orders.Created",    # uppercase
        ".quantum.orders",           # leading dot
        "quantum.orders.",           # trailing dot
        "quantum orders created",    # spaces
    ])
    def test_invalid_metric_names_rejected(self, name):
        assert not self.VALID_METRIC_PATTERN.match(name), \
            f"Expected invalid metric name to fail: {name}"
