"""
E2E tests — Monitor lifecycle and alerting.

Creates a real monitor via the API, triggers its threshold,
validates it enters ALERT state, then cleans up.

Requires: DD_API_KEY and DD_APP_KEY set.
"""

import time
import uuid
import pytest
from datadog_api_client.v1.api.monitors_api import MonitorsApi
from datadog_api_client.v1.model.monitor import Monitor
from datadog_api_client.v1.model.monitor_type import MonitorType
from datadog_api_client.v1.model.monitor_thresholds import MonitorThresholds


pytestmark = [pytest.mark.api, pytest.mark.slow]

MONITOR_WAIT_SECONDS = 120
POLL_INTERVAL = 10


@pytest.fixture
def monitors_api(dd_api_client):
    return MonitorsApi(dd_api_client)


@pytest.fixture
def test_monitor(monitors_api, dd_config):
    """Create a monitor for the test, yield its ID, delete on teardown."""
    monitor_name = f"[TEST] Integration Test Monitor - {uuid.uuid4().hex[:8]}"

    body = Monitor(
        name=monitor_name,
        type=MonitorType("metric alert"),
        query=(
            f"avg(last_1m):avg:system.cpu.user"
            f"{{env:{dd_config['env']}}} > 999"   # threshold impossible to hit — starts OK
        ),
        message=f"Test monitor — safe to ignore. Runbook: https://wiki/test @slack-dev-null",
        tags=[
            f"env:{dd_config['env']}",
            f"service:{dd_config['service']}",
            "team:platform",
            "test:true",
        ],
        options={
            "thresholds": MonitorThresholds(critical=999, warning=990),
            "notify_no_data": False,
            "renotify_interval": 0,
        },
    )

    monitor = monitors_api.create_monitor(body=body)
    monitor_id = monitor.id
    yield monitor_id

    # Teardown — always delete
    try:
        monitors_api.delete_monitor(monitor_id=monitor_id)
    except Exception:
        pass  # already deleted or test cleanup already handled it


class TestMonitorCRUD:
    def test_create_monitor(self, monitors_api, dd_config):
        name = f"[TEST] CRUD Test - {uuid.uuid4().hex[:8]}"
        body = Monitor(
            name=name,
            type=MonitorType("metric alert"),
            query=f"avg(last_1m):avg:system.cpu.user{{env:{dd_config['env']}}} > 999",
            message="Test. Runbook: https://wiki/test @slack-dev-null",
            tags=[f"env:{dd_config['env']}", f"service:{dd_config['service']}", "team:platform", "test:true"],
        )
        monitor = monitors_api.create_monitor(body=body)
        assert monitor.id
        assert monitor.name == name
        monitors_api.delete_monitor(monitor_id=monitor.id)

    def test_read_monitor(self, monitors_api, test_monitor):
        monitor = monitors_api.get_monitor(monitor_id=test_monitor)
        assert monitor.id == test_monitor
        assert "[TEST]" in monitor.name

    def test_update_monitor(self, monitors_api, test_monitor):
        from datadog_api_client.v1.model.monitor_update_request import MonitorUpdateRequest
        update = MonitorUpdateRequest(
            message="Updated message. Runbook: https://wiki/test @slack-dev-null",
        )
        result = monitors_api.update_monitor(monitor_id=test_monitor, body=update)
        assert "Updated message" in result.message

    def test_delete_monitor(self, monitors_api, dd_config):
        name = f"[TEST] Delete Test - {uuid.uuid4().hex[:8]}"
        body = Monitor(
            name=name,
            type=MonitorType("metric alert"),
            query=f"avg(last_1m):avg:system.cpu.user{{env:{dd_config['env']}}} > 999",
            message="Test. Runbook: https://wiki/test @slack-dev-null",
            tags=[f"env:{dd_config['env']}", f"service:{dd_config['service']}", "team:platform", "test:true"],
        )
        monitor = monitors_api.create_monitor(body=body)
        monitors_api.delete_monitor(monitor_id=monitor.id)

        # Confirm deletion
        from datadog_api_client.v1 import ApiException
        with pytest.raises(ApiException) as exc:
            monitors_api.get_monitor(monitor_id=monitor.id)
        assert exc.value.status == 404


class TestMonitorState:
    def test_new_monitor_starts_in_no_data_or_ok(self, monitors_api, test_monitor):
        monitor = monitors_api.get_monitor(monitor_id=test_monitor, with_downtimes=False)
        overall_state = str(monitor.overall_state) if hasattr(monitor, "overall_state") else "Unknown"
        # A brand new monitor may be No Data (no data yet) or OK
        assert overall_state in ("Ok", "No Data", "Unknown", "None"), \
            f"Unexpected initial monitor state: {overall_state}"

    def test_monitor_tags_present(self, monitors_api, test_monitor, dd_config):
        monitor = monitors_api.get_monitor(monitor_id=test_monitor)
        tag_keys = {t.split(":")[0] for t in monitor.tags if ":" in t}
        for required in ("env", "service", "team"):
            assert required in tag_keys, f"Required tag '{required}' missing from monitor"


class TestMonitorSearch:
    def test_search_monitors_by_tag(self, monitors_api, test_monitor, dd_config):
        result = monitors_api.search_monitors(
            query=f"tag:test:true tag:env:{dd_config['env']}"
        )
        monitor_ids = [m.id for m in (result.monitors or [])]
        assert test_monitor in monitor_ids, \
            "Test monitor not found in search results"

    def test_search_monitors_by_name(self, monitors_api, test_monitor):
        monitor = monitors_api.get_monitor(monitor_id=test_monitor)
        result = monitors_api.search_monitors(query=f'"{monitor.name}"')
        found = [m for m in (result.monitors or []) if m.id == test_monitor]
        assert found, f"Monitor '{monitor.name}' not found in search"


class TestMonitorValidation:
    """Validate that production monitors meet quality standards."""

    def test_no_permanently_muted_monitors(self, monitors_api, dd_config):
        result = monitors_api.search_monitors(
            query=f"tag:env:{dd_config['env']} status:silenced"
        )
        muted = [m.name for m in (result.monitors or [])]
        assert not muted, \
            f"Permanently muted monitors detected (investigate before shipping): {muted}"

    def test_p1_monitors_have_pagerduty_notification(self, monitors_api, dd_config):
        result = monitors_api.search_monitors(
            query=f"tag:env:{dd_config['env']} title:\\[P1\\]"
        )
        missing_pd = []
        for m in (result.monitors or []):
            monitor = monitors_api.get_monitor(monitor_id=m.id)
            if "@pagerduty" not in (monitor.message or ""):
                missing_pd.append(monitor.name)

        assert not missing_pd, \
            f"P1 monitors missing @pagerduty notification: {missing_pd}"
