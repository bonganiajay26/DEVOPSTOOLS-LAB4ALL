"""
Unit tests — monitor configuration validation.

Validates monitor definitions for naming conventions, threshold sanity,
required message fields, and notification routing — without a live API.
"""

import pytest
import re

MONITOR_NAME_PATTERN = re.compile(r"^\[(P[1-4])\] .+ - .+ - (production|staging|development|test)$")
SEVERITY_LEVELS = {"P1", "P2", "P3", "P4"}
REQUIRED_MESSAGE_FIELDS = ["runbook", "dashboard"]


def validate_monitor(monitor: dict) -> list[str]:
    """Return list of validation errors for a monitor definition."""
    errors = []

    name = monitor.get("name", "")
    if not MONITOR_NAME_PATTERN.match(name):
        errors.append(f"Name '{name}' does not match pattern: [Px] Service - Issue - Env")

    thresholds = monitor.get("thresholds", {})
    critical = thresholds.get("critical")
    warning = thresholds.get("warning")

    if critical is None:
        errors.append("Missing critical threshold")

    if warning is not None and critical is not None:
        # Warning should be less severe than critical
        # (works for both > and < monitors — just check they differ)
        if warning == critical:
            errors.append("Warning and critical thresholds are identical")

    message = monitor.get("message", "")
    if not message:
        errors.append("Empty monitor message")
    if "runbook" not in message.lower():
        errors.append("Message missing runbook link")
    if "@" not in message:
        errors.append("Message missing notification handle (@slack / @pagerduty)")

    tags = monitor.get("tags", [])
    tag_keys = {t.split(":")[0] for t in tags if ":" in t}
    for required in ("env", "service", "team"):
        if required not in tag_keys:
            errors.append(f"Missing required tag: {required}")

    return errors


# ── Valid monitor fixture ─────────────────────────────────────────

VALID_MONITOR = {
    "name": "[P1] payment-service - Error Rate Critical - production",
    "type": "metric alert",
    "query": "avg(last_5m):sum:trace.web.request.errors{service:payment-service}.as_rate() / sum:trace.web.request.hits{service:payment-service}.as_rate() * 100 > 5",
    "message": "Error rate is critical.\nRunbook: https://wiki.quantum.com/runbooks/payment-service\n@slack-alerts-critical @pagerduty-critical",
    "thresholds": {"critical": 5, "warning": 2},
    "tags": ["env:production", "service:payment-service", "team:backend"],
}


class TestMonitorNaming:
    def test_valid_monitor_name_passes(self):
        assert MONITOR_NAME_PATTERN.match("[P1] payment-service - Error Rate Critical - production")
        assert MONITOR_NAME_PATTERN.match("[P2] api-gateway - High Latency p99 - staging")
        assert MONITOR_NAME_PATTERN.match("[P3] infra - Disk Space High - production")

    def test_missing_severity_prefix_fails(self):
        assert not MONITOR_NAME_PATTERN.match("payment-service - Error Rate - production")

    def test_invalid_severity_fails(self):
        assert not MONITOR_NAME_PATTERN.match("[P5] service - issue - production")

    def test_missing_env_suffix_fails(self):
        assert not MONITOR_NAME_PATTERN.match("[P1] service - Error Rate Critical")

    def test_invalid_env_in_name_fails(self):
        assert not MONITOR_NAME_PATTERN.match("[P1] service - Error Rate Critical - prod")


class TestMonitorThresholds:
    def test_valid_monitor_has_no_errors(self):
        errors = validate_monitor(VALID_MONITOR)
        assert not errors, f"Unexpected errors: {errors}"

    def test_missing_critical_threshold_flagged(self):
        monitor = {**VALID_MONITOR, "thresholds": {"warning": 2}}
        errors = validate_monitor(monitor)
        assert any("critical threshold" in e for e in errors)

    def test_identical_thresholds_flagged(self):
        monitor = {**VALID_MONITOR, "thresholds": {"critical": 5, "warning": 5}}
        errors = validate_monitor(monitor)
        assert any("identical" in e for e in errors)


class TestMonitorMessage:
    def test_valid_message_passes(self):
        errors = validate_monitor(VALID_MONITOR)
        assert not any("message" in e.lower() or "runbook" in e.lower() or "notification" in e.lower() for e in errors)

    def test_missing_runbook_flagged(self):
        monitor = {**VALID_MONITOR, "message": "Alert fired. @slack-alerts-critical"}
        errors = validate_monitor(monitor)
        assert any("runbook" in e for e in errors)

    def test_missing_notification_handle_flagged(self):
        monitor = {**VALID_MONITOR, "message": "Alert fired. Runbook: https://wiki/runbook"}
        errors = validate_monitor(monitor)
        assert any("notification handle" in e for e in errors)

    def test_empty_message_flagged(self):
        monitor = {**VALID_MONITOR, "message": ""}
        errors = validate_monitor(monitor)
        assert any("Empty" in e for e in errors)


class TestMonitorTags:
    def test_all_required_tags_pass(self):
        errors = validate_monitor(VALID_MONITOR)
        assert not any("Missing required tag" in e for e in errors)

    @pytest.mark.parametrize("missing_tag", ["env", "service", "team"])
    def test_missing_required_tag_flagged(self, missing_tag):
        tags = [t for t in VALID_MONITOR["tags"] if not t.startswith(f"{missing_tag}:")]
        monitor = {**VALID_MONITOR, "tags": tags}
        errors = validate_monitor(monitor)
        assert any(missing_tag in e for e in errors)


class TestMultipleMonitors:
    """Validate a typical set of core monitors."""

    CORE_MONITORS = [
        {
            "name": "[P1] my-api - Error Rate Critical - production",
            "type": "metric alert",
            "query": "avg(last_5m):...",
            "message": "Error rate high. Runbook: https://wiki/runbook @pagerduty-critical",
            "thresholds": {"critical": 5, "warning": 2},
            "tags": ["env:production", "service:my-api", "team:platform"],
        },
        {
            "name": "[P2] my-api - High Latency p99 - production",
            "type": "metric alert",
            "query": "avg(last_10m):...",
            "message": "Latency high. Runbook: https://wiki/runbook @slack-alerts-warning",
            "thresholds": {"critical": 2000, "warning": 1000},
            "tags": ["env:production", "service:my-api", "team:platform"],
        },
        {
            "name": "[P3] my-api - Disk Space High - production",
            "type": "metric alert",
            "query": "max(last_15m):...",
            "message": "Disk almost full. Runbook: https://wiki/runbook @slack-alerts-info",
            "thresholds": {"critical": 0.90, "warning": 0.75},
            "tags": ["env:production", "service:my-api", "team:platform"],
        },
    ]

    def test_all_core_monitors_valid(self):
        all_errors = {}
        for monitor in self.CORE_MONITORS:
            errors = validate_monitor(monitor)
            if errors:
                all_errors[monitor["name"]] = errors
        assert not all_errors, f"Monitor validation failures: {all_errors}"

    def test_no_duplicate_monitor_names(self):
        names = [m["name"] for m in self.CORE_MONITORS]
        assert len(names) == len(set(names)), "Duplicate monitor names detected"
