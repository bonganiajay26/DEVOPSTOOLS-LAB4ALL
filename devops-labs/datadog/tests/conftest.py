"""
Pytest configuration and shared fixtures for Datadog test suite.

Required environment variables:
  DD_API_KEY   - Datadog API key
  DD_APP_KEY   - Datadog Application key
  DD_SITE      - Datadog site (default: datadoghq.com)
  DD_ENV       - Environment under test (default: production)
  DD_SERVICE   - Service name (default: test-service)
  DD_AGENT_HOST - Agent host (default: localhost)
"""

import os
import time
import pytest
from dotenv import load_dotenv

load_dotenv()


# ── Shared config ─────────────────────────────────────────────────

def pytest_configure(config):
    config.addinivalue_line("markers", "agent: tests that require a running Datadog agent")
    config.addinivalue_line("markers", "api: tests that call the Datadog API")
    config.addinivalue_line("markers", "slow: tests that take more than 30 seconds")


@pytest.fixture(scope="session")
def dd_config():
    """Return base Datadog configuration from environment."""
    api_key = os.environ.get("DD_API_KEY")
    app_key = os.environ.get("DD_APP_KEY")

    if not api_key:
        pytest.skip("DD_API_KEY not set — skipping API tests")
    if not app_key:
        pytest.skip("DD_APP_KEY not set — skipping API tests")

    return {
        "api_key": api_key,
        "app_key": app_key,
        "site": os.environ.get("DD_SITE", "datadoghq.com"),
        "env": os.environ.get("DD_ENV", "production"),
        "service": os.environ.get("DD_SERVICE", "test-service"),
        "agent_host": os.environ.get("DD_AGENT_HOST", "localhost"),
        "agent_apm_port": int(os.environ.get("DD_TRACE_AGENT_PORT", "8126")),
        "agent_statsd_port": int(os.environ.get("DD_DOGSTATSD_PORT", "8125")),
    }


@pytest.fixture(scope="session")
def dd_api_client(dd_config):
    """Configured Datadog API client."""
    from datadog_api_client import ApiClient, Configuration

    configuration = Configuration()
    configuration.api_key["apiKeyAuth"] = dd_config["api_key"]
    configuration.api_key["appKeyAuth"] = dd_config["app_key"]
    configuration.server_variables["site"] = dd_config["site"]
    return ApiClient(configuration)


@pytest.fixture
def unique_tag():
    """A unique tag for isolating test resources."""
    return f"test-run:{int(time.time())}"
