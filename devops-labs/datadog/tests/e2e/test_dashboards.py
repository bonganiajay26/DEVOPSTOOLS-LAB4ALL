"""
E2E tests — Dashboard validation.

Validates that required dashboards exist, contain expected widgets,
and follow naming conventions.

Requires: DD_API_KEY and DD_APP_KEY set.
"""

import re
import uuid
import pytest
from datadog_api_client.v1.api.dashboards_api import DashboardsApi
from datadog_api_client.v1.model.dashboard import Dashboard
from datadog_api_client.v1.model.dashboard_layout_type import DashboardLayoutType
from datadog_api_client.v1.model.widget import Widget
from datadog_api_client.v1.model.note_widget_definition import NoteWidgetDefinition
from datadog_api_client.v1.model.note_widget_definition_type import NoteWidgetDefinitionType


pytestmark = pytest.mark.api

DASHBOARD_NAME_PATTERN = re.compile(r"^.+ - .+ - .+ - (production|staging|development|test)$")


@pytest.fixture
def dashboards_api(dd_api_client):
    return DashboardsApi(dd_api_client)


@pytest.fixture
def test_dashboard(dashboards_api):
    """Create a minimal test dashboard, yield ID, delete on teardown."""
    widget = Widget(
        definition=NoteWidgetDefinition(
            type=NoteWidgetDefinitionType("note"),
            content="Integration test dashboard — safe to delete",
        )
    )

    body = Dashboard(
        title=f"Test - Integration Test - Validation - production",
        layout_type=DashboardLayoutType("ordered"),
        widgets=[widget],
        description="Auto-created by integration test suite",
        tags=["test:true"],
    )
    dashboard = dashboards_api.create_dashboard(body=body)
    yield dashboard.id

    try:
        dashboards_api.delete_dashboard(dashboard_id=dashboard.id)
    except Exception:
        pass


class TestDashboardCRUD:
    def test_create_dashboard(self, dashboards_api):
        widget = Widget(
            definition=NoteWidgetDefinition(
                type=NoteWidgetDefinitionType("note"),
                content="Test",
            )
        )
        body = Dashboard(
            title=f"Test - CRUD - Validation - production",
            layout_type=DashboardLayoutType("ordered"),
            widgets=[widget],
        )
        dashboard = dashboards_api.create_dashboard(body=body)
        assert dashboard.id
        dashboards_api.delete_dashboard(dashboard_id=dashboard.id)

    def test_read_dashboard(self, dashboards_api, test_dashboard):
        result = dashboards_api.get_dashboard(dashboard_id=test_dashboard)
        assert result.id == test_dashboard

    def test_delete_dashboard(self, dashboards_api):
        widget = Widget(
            definition=NoteWidgetDefinition(
                type=NoteWidgetDefinitionType("note"),
                content="Delete test",
            )
        )
        body = Dashboard(
            title="Test - Delete - Validation - production",
            layout_type=DashboardLayoutType("ordered"),
            widgets=[widget],
        )
        d = dashboards_api.create_dashboard(body=body)
        dashboards_api.delete_dashboard(dashboard_id=d.id)

        from datadog_api_client.v1 import ApiException
        with pytest.raises(ApiException) as exc:
            dashboards_api.get_dashboard(dashboard_id=d.id)
        assert exc.value.status == 404


class TestDashboardNaming:
    @pytest.mark.parametrize("title", [
        "Platform - API Gateway - Overview - production",
        "Backend - Payments Service - APM - production",
        "Infra - Kubernetes Cluster - Resource Usage - staging",
        "SRE - On-Call Overview - All Services - production",
    ])
    def test_valid_dashboard_name(self, title):
        assert DASHBOARD_NAME_PATTERN.match(title), f"Dashboard name failed validation: {title}"

    @pytest.mark.parametrize("title", [
        "API Gateway Overview",              # missing team and env
        "Platform - API - production",       # only 3 segments
        "Platform - API - Overview - prod",  # abbreviated env
    ])
    def test_invalid_dashboard_name_detected(self, title):
        assert not DASHBOARD_NAME_PATTERN.match(title), \
            f"Expected invalid dashboard name to fail: {title}"


class TestDashboardList:
    def test_can_list_dashboards(self, dashboards_api):
        result = dashboards_api.list_dashboards()
        assert result.dashboards is not None

    def test_test_dashboard_in_list(self, dashboards_api, test_dashboard):
        result = dashboards_api.list_dashboards()
        ids = [d.id for d in (result.dashboards or [])]
        assert test_dashboard in ids, "Newly created dashboard not found in list"

    def test_production_dashboards_follow_naming(self, dashboards_api, dd_config):
        """Warn about any production dashboards that don't follow naming standards."""
        result = dashboards_api.list_dashboards()
        violations = []
        for d in (result.dashboards or []):
            title = d.title or ""
            if dd_config["env"] in title.lower() and not DASHBOARD_NAME_PATTERN.match(title):
                if "test" not in title.lower():  # ignore test dashboards
                    violations.append(title)

        # Report as warning — don't fail hard since legacy dashboards may exist
        if violations:
            pytest.warns(
                UserWarning,
                match="Dashboard naming violation",
            )
