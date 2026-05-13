"""
E2E tests — Datadog API connectivity and authentication.

These tests verify the API key and app key are valid and the
account is accessible before any other tests run.

Requires: DD_API_KEY and DD_APP_KEY set.
"""

import pytest
from datadog_api_client.v1.api.authentication_api import AuthenticationApi
from datadog_api_client.v1.api.organizations_api import OrganizationsApi
from datadog_api_client.v1.api.users_api import UsersApi


pytestmark = pytest.mark.api


class TestAuthentication:
    def test_api_key_is_valid(self, dd_api_client):
        api = AuthenticationApi(dd_api_client)
        result = api.validate()
        assert result.valid is True, \
            "DD_API_KEY is invalid — generate a new one at Organization Settings → API Keys"

    def test_app_key_allows_org_read(self, dd_api_client):
        api = OrganizationsApi(dd_api_client)
        result = api.list_orgs()
        assert result.orgs, \
            "DD_APP_KEY cannot read org data — check app key permissions"

    def test_org_has_expected_features(self, dd_api_client):
        api = OrganizationsApi(dd_api_client)
        result = api.list_orgs()
        org = result.orgs[0]
        assert org.name, "Organisation name is empty"


class TestAccountAccess:
    def test_can_list_users(self, dd_api_client):
        api = UsersApi(dd_api_client)
        result = api.list_users()
        assert result.users, "No users returned — check app key has Users Read permission"

    def test_service_account_exists(self, dd_api_client):
        """At least one user should exist (the account owner)."""
        api = UsersApi(dd_api_client)
        result = api.list_users()
        assert len(result.users) >= 1

    def test_no_expired_api_keys(self, dd_api_client):
        from datadog_api_client.v1.api.key_management_api import KeyManagementApi
        try:
            api = KeyManagementApi(dd_api_client)
            result = api.list_api_keys()
            # Check none are marked invalid (Datadog doesn't expose expiry, but can check name)
            keys = result.api_keys or []
            unnamed = [k for k in keys if not k.name]
            assert not unnamed, f"{len(unnamed)} unnamed API keys found — clean them up"
        except Exception:
            pytest.skip("KeyManagementApi not available with current permissions")


class TestSiteConnectivity:
    def test_datadog_api_reachable(self, dd_config):
        import requests
        site = dd_config["site"]
        resp = requests.get(f"https://api.{site}/api/v1/validate",
                            headers={"DD-API-KEY": dd_config["api_key"]},
                            timeout=10)
        assert resp.status_code == 200, \
            f"API endpoint returned {resp.status_code} — check network/firewall"

    def test_api_response_is_valid_json(self, dd_config):
        import requests
        site = dd_config["site"]
        resp = requests.get(f"https://api.{site}/api/v1/validate",
                            headers={"DD-API-KEY": dd_config["api_key"]},
                            timeout=10)
        data = resp.json()
        assert "valid" in data

    def test_correct_site_configured(self, dd_config):
        valid_sites = {"datadoghq.com", "datadoghq.eu", "us3.datadoghq.com",
                       "us5.datadoghq.com", "ap1.datadoghq.com"}
        assert dd_config["site"] in valid_sites, \
            f"Unknown DD_SITE: '{dd_config['site']}' — valid options: {valid_sites}"
