# Datadog Test Suite

Complete test coverage across four layers: unit, integration, E2E, and agent health.

## Structure

```
tests/
├── unit/                        # No credentials needed — run anywhere
│   ├── test_tagging.py              # Tag format, required keys, PII, cardinality
│   └── test_monitor_config.py       # Monitor naming, thresholds, messages
│
├── integration/                 # Requires agent + API keys
│   ├── test_agent.py                # Agent health, ports, log/APM status
│   ├── test_apm.py                  # Trace submission + API verification
│   ├── test_logs.py                 # Log submission + search retrieval
│   └── test_metrics.py             # DogStatsD + API verification
│
├── e2e/                         # Full lifecycle against live account
│   ├── test_api_connectivity.py     # Auth, site, org access
│   ├── test_monitors.py             # CRUD, state, naming, P1 notifications
│   └── test_dashboards.py           # CRUD, naming conventions
│
├── fixtures/
│   └── .env.example                 # Copy to .env and fill in
│
├── conftest.py                  # Shared fixtures and config
├── pytest.ini                   # Test runner config (default: unit only)
├── requirements.txt             # Python dependencies
└── run-tests.sh                 # Convenience runner script
```

## Quick Start

```bash
cd devops-labs/datadog/tests

# 1. Install dependencies
pip install -r requirements.txt

# 2. Unit tests only (no credentials — runs in CI by default)
./run-tests.sh unit

# 3. Full suite (requires keys)
cp fixtures/.env.example .env
# edit .env with your DD_API_KEY and DD_APP_KEY
./run-tests.sh all
```

## Running Specific Suites

```bash
# Unit only (fast, ~2 seconds)
pytest -m unit

# Integration — requires agent + API keys
pytest -m "agent or integration"

# E2E — creates/deletes real Datadog resources
pytest -m "e2e or api"

# Everything
pytest -m "unit or integration or e2e or agent or api"

# Single file
pytest integration/test_agent.py -v

# Single test
pytest unit/test_tagging.py::TestTagFormat::test_valid_tag_passes -v
```

## Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `DD_API_KEY` | For API tests | — | Datadog API key |
| `DD_APP_KEY` | For API tests | — | Datadog Application key |
| `DD_SITE` | No | `datadoghq.com` | Datadog site |
| `DD_ENV` | No | `production` | Environment under test |
| `DD_SERVICE` | No | `test-service` | Service name for test tags |
| `DD_AGENT_HOST` | No | `localhost` | Agent hostname |
| `DD_TRACE_AGENT_PORT` | No | `8126` | APM port |
| `DD_DOGSTATSD_PORT` | No | `8125` | DogStatsD port |

## Test Markers

| Marker | Description | Needs |
|---|---|---|
| `unit` | No external deps | Nothing |
| `agent` | Requires local agent | Running `datadog-agent` |
| `api` | Calls Datadog API | `DD_API_KEY` + `DD_APP_KEY` |
| `slow` | Waits for ingestion (30–120s) | Patience |
| `e2e` | Creates/deletes real resources | API keys + permissions |

## CI Integration (GitHub Actions example)

```yaml
- name: Run Datadog unit tests
  run: |
    pip install -r devops-labs/datadog/tests/requirements.txt
    cd devops-labs/datadog/tests
    pytest -m unit --tb=short

- name: Run Datadog E2E tests
  if: github.ref == 'refs/heads/main'
  env:
    DD_API_KEY: ${{ secrets.DD_API_KEY }}
    DD_APP_KEY: ${{ secrets.DD_APP_KEY }}
  run: |
    cd devops-labs/datadog/tests
    pytest -m "e2e or api" --tb=short
```
