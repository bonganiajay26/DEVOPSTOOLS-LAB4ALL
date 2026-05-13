"""
Integration tests — Datadog Agent health.

Requires a running Datadog agent on the local host.
Mark: @pytest.mark.agent
"""

import socket
import subprocess
import platform
import pytest
import requests


pytestmark = pytest.mark.agent


def is_linux():
    return platform.system() == "Linux"


def agent_status() -> str:
    """Run 'datadog-agent status' and return output."""
    try:
        result = subprocess.run(
            ["datadog-agent", "status"],
            capture_output=True, text=True, timeout=30
        )
        return result.stdout + result.stderr
    except FileNotFoundError:
        pytest.skip("datadog-agent binary not found — skipping agent tests")
    except subprocess.TimeoutExpired:
        pytest.fail("datadog-agent status timed out after 30s")


# ── Agent process ─────────────────────────────────────────────────

class TestAgentProcess:
    @pytest.mark.skipif(not is_linux(), reason="systemctl only on Linux")
    def test_agent_service_running(self):
        result = subprocess.run(
            ["systemctl", "is-active", "datadog-agent"],
            capture_output=True, text=True
        )
        assert result.stdout.strip() == "active", "datadog-agent service is not active"

    def test_agent_status_command_succeeds(self):
        status = agent_status()
        assert "Agent" in status, "Unexpected agent status output"

    def test_api_key_valid(self):
        status = agent_status()
        assert "API Key valid" in status or "API key ending" in status, \
            "API key is invalid or not reported — check DD_API_KEY"

    def test_no_clock_drift(self):
        status = agent_status()
        # Datadog warns when drift > 10 seconds
        assert "NTP offset" not in status or "WARNING" not in status, \
            "Clock drift detected — sync NTP"


# ── Network / port connectivity ───────────────────────────────────

class TestAgentPorts:
    def _port_open(self, host: str, port: int) -> bool:
        try:
            with socket.create_connection((host, port), timeout=3):
                return True
        except (ConnectionRefusedError, OSError):
            return False

    def test_apm_port_open(self, dd_config):
        host = dd_config["agent_host"]
        port = dd_config["agent_apm_port"]
        assert self._port_open(host, port), \
            f"APM port {port} not reachable on {host} — check apm_config.apm_non_local_traffic"

    def test_statsd_port_open(self, dd_config):
        host = dd_config["agent_host"]
        port = dd_config["agent_statsd_port"]
        # DogStatsD is UDP — attempt a UDP send
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.settimeout(2)
            sock.sendto(b"test.metric:1|c", (host, port))
            sock.close()
        except OSError as e:
            pytest.fail(f"DogStatsD port {port} unreachable: {e}")

    def test_datadog_api_reachable(self, dd_config):
        site = dd_config["site"]
        try:
            resp = requests.get(f"https://app.{site}", timeout=10)
            assert resp.status_code < 500, f"Datadog site returned {resp.status_code}"
        except requests.ConnectionError:
            pytest.fail(f"Cannot reach https://app.{site} — check firewall/proxy")


# ── Log collection ────────────────────────────────────────────────

class TestLogCollection:
    def test_logs_agent_running(self):
        status = agent_status()
        assert "Logs Agent" in status, \
            "Logs Agent not found in status — set logs_enabled: true in datadog.yaml"

    def test_no_log_collection_errors(self):
        status = agent_status()
        # Look for error lines specifically in the Logs section
        lines = status.split("\n")
        in_logs_section = False
        errors = []
        for line in lines:
            if "Logs Agent" in line:
                in_logs_section = True
            if in_logs_section and "Error" in line and "0 errors" not in line:
                errors.append(line.strip())
        assert not errors, f"Log collection errors found: {errors}"


# ── APM ───────────────────────────────────────────────────────────

class TestAPMAgent:
    def test_apm_agent_enabled(self):
        status = agent_status()
        assert "APM Agent" in status, \
            "APM Agent not in status — set apm_config.enabled: true"

    def test_apm_not_reporting_errors(self):
        status = agent_status()
        lines = status.split("\n")
        in_apm_section = False
        for line in lines:
            if "APM Agent" in line:
                in_apm_section = True
            if in_apm_section and "Status: Not running" in line:
                pytest.fail("APM Agent is not running")


# ── Integration checks ────────────────────────────────────────────

class TestIntegrations:
    def test_no_failing_integrations(self):
        status = agent_status()
        assert "Error" not in status or "0 Errors" in status, \
            "One or more integrations have errors — run: datadog-agent status"

    def test_cpu_check_running(self):
        status = agent_status()
        assert "cpu" in status.lower(), "CPU check not found in agent status"

    def test_disk_check_running(self):
        status = agent_status()
        assert "disk" in status.lower(), "Disk check not found in agent status"

    def test_network_check_running(self):
        status = agent_status()
        assert "network" in status.lower(), "Network check not found in agent status"
