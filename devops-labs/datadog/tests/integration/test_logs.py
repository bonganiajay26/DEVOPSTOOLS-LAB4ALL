"""
Integration tests — Log submission and pipeline validation.

Submits logs via the Datadog Logs API and verifies they appear
in Log Explorer with correct parsing, tags, and status.

Requires: DD_API_KEY and DD_APP_KEY set.
"""

import time
import uuid
import pytest
from datadog_api_client.v2.api.logs_api import LogsApi
from datadog_api_client.v2.model.http_log import HTTPLog
from datadog_api_client.v2.model.http_log_item import HTTPLogItem


pytestmark = [pytest.mark.api, pytest.mark.slow]

LOG_WAIT_SECONDS = 30


def submit_log(dd_api_client, service: str, env: str, message: str,
               level: str = "info", test_id: str = "") -> str:
    """Submit a single log via the Datadog Logs API. Returns the test_id."""
    from datadog_api_client.v2 import ApiClient as V2ApiClient

    test_id = test_id or str(uuid.uuid4())

    log_item = HTTPLogItem(
        ddsource="python",
        ddtags=f"env:{env},service:{service},test.id:{test_id},test:true",
        hostname="test-host",
        message=f"{message} [test_id={test_id}]",
        service=service,
    )

    # Re-use connection but target v2 API
    with dd_api_client as client:
        api = LogsApi(client)
        api.submit_log(body=HTTPLog([log_item]))

    return test_id


class TestLogSubmission:
    def test_info_log_submitted(self, dd_api_client, dd_config):
        test_id = submit_log(
            dd_api_client,
            service=dd_config["service"],
            env=dd_config["env"],
            message="INFO test log from integration test suite",
            level="info"
        )
        assert test_id

    def test_error_log_submitted(self, dd_api_client, dd_config):
        test_id = submit_log(
            dd_api_client,
            service=dd_config["service"],
            env=dd_config["env"],
            message="ERROR simulated error from integration test suite",
            level="error"
        )
        assert test_id

    def test_warn_log_submitted(self, dd_api_client, dd_config):
        test_id = submit_log(
            dd_api_client,
            service=dd_config["service"],
            env=dd_config["env"],
            message="WARN elevated latency detected — integration test",
            level="warn"
        )
        assert test_id

    def test_batch_logs_submitted(self, dd_api_client, dd_config):
        """Batch 10 logs in one API call."""
        from datadog_api_client.v2 import ApiClient as V2ApiClient

        items = [
            HTTPLogItem(
                ddsource="python",
                ddtags=f"env:{dd_config['env']},service:{dd_config['service']},test:batch",
                hostname="test-host",
                message=f"Batch log {i} from integration test",
                service=dd_config["service"],
            )
            for i in range(10)
        ]

        with dd_api_client as client:
            api = LogsApi(client)
            api.submit_log(body=HTTPLog(items))


class TestLogRetrieval:
    """Verify submitted logs are searchable via the Logs API."""

    def test_submitted_log_appears_in_search(self, dd_api_client, dd_config):
        from datadog_api_client.v2.api.logs_api import LogsApi
        from datadog_api_client.v2.model.logs_list_request import LogsListRequest
        from datadog_api_client.v2.model.logs_list_request_page import LogsListRequestPage
        from datadog_api_client.v2.model.logs_query_filter import LogsQueryFilter
        from datadog_api_client.v2.model.logs_sort import LogsSort

        test_id = str(uuid.uuid4())
        submit_log(
            dd_api_client,
            service=dd_config["service"],
            env=dd_config["env"],
            message=f"SEARCH_TEST unique marker",
            test_id=test_id
        )

        time.sleep(LOG_WAIT_SECONDS)

        with dd_api_client as client:
            api = LogsApi(client)
            request = LogsListRequest(
                filter=LogsQueryFilter(
                    query=f"test.id:{test_id} service:{dd_config['service']}",
                    _from=f"{int(time.time()) - 300}",
                    to=f"{int(time.time())}",
                ),
                page=LogsListRequestPage(limit=10),
                sort=LogsSort("-timestamp"),
            )
            result = api.list_logs(body=request)

        assert result.data, \
            f"Log with test_id={test_id} not found after {LOG_WAIT_SECONDS}s — check log pipeline"

    def test_log_has_correct_service_tag(self, dd_api_client, dd_config):
        from datadog_api_client.v2.api.logs_api import LogsApi
        from datadog_api_client.v2.model.logs_list_request import LogsListRequest
        from datadog_api_client.v2.model.logs_list_request_page import LogsListRequestPage
        from datadog_api_client.v2.model.logs_query_filter import LogsQueryFilter
        from datadog_api_client.v2.model.logs_sort import LogsSort

        test_id = str(uuid.uuid4())
        submit_log(
            dd_api_client,
            service=dd_config["service"],
            env=dd_config["env"],
            message="SERVICE_TAG_CHECK",
            test_id=test_id
        )
        time.sleep(LOG_WAIT_SECONDS)

        with dd_api_client as client:
            api = LogsApi(client)
            request = LogsListRequest(
                filter=LogsQueryFilter(
                    query=f"test.id:{test_id}",
                    _from=f"{int(time.time()) - 300}",
                    to=f"{int(time.time())}",
                ),
                page=LogsListRequestPage(limit=1),
                sort=LogsSort("-timestamp"),
            )
            result = api.list_logs(body=request)

        assert result.data, f"Log not found: test_id={test_id}"
        log = result.data[0]
        attributes = log.attributes.get("tags", [])
        assert any(f"service:{dd_config['service']}" in t for t in attributes), \
            f"service tag missing from retrieved log. Tags: {attributes}"
