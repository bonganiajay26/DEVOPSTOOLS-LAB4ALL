#!/usr/bin/env bash
# Datadog Test Suite Runner
# Usage: ./run-tests.sh [suite]
#   suites: unit | integration | e2e | all
set -euo pipefail

SUITE="${1:-unit}"
REPORT_DIR="reports"

mkdir -p "$REPORT_DIR"

echo "======================================"
echo " Datadog Test Suite — ${SUITE^^}"
echo "======================================"

# Load .env if present
if [ -f ".env" ]; then
  set -a; source .env; set +a
  echo "[info] Loaded .env"
fi

# Install dependencies if needed
if ! python3 -c "import pytest" 2>/dev/null; then
  echo "[info] Installing dependencies..."
  pip install -q -r requirements.txt
fi

case "$SUITE" in
  unit)
    echo "[info] Running unit tests (no credentials required)..."
    python3 -m pytest -m unit -v --tb=short \
      --html="$REPORT_DIR/unit-report.html" --self-contained-html
    ;;

  integration)
    echo "[info] Running integration tests (requires running agent + API keys)..."
    : "${DD_API_KEY:?DD_API_KEY required for integration tests}"
    : "${DD_APP_KEY:?DD_APP_KEY required for integration tests}"
    python3 -m pytest -m "integration or agent" -v --tb=short \
      --html="$REPORT_DIR/integration-report.html" --self-contained-html
    ;;

  e2e)
    echo "[info] Running E2E tests (requires API keys — creates real resources)..."
    : "${DD_API_KEY:?DD_API_KEY required for e2e tests}"
    : "${DD_APP_KEY:?DD_APP_KEY required for e2e tests}"
    python3 -m pytest -m "e2e or api" -v --tb=short \
      --html="$REPORT_DIR/e2e-report.html" --self-contained-html
    ;;

  all)
    echo "[info] Running full test suite..."
    : "${DD_API_KEY:?DD_API_KEY required for full suite}"
    : "${DD_APP_KEY:?DD_APP_KEY required for full suite}"
    python3 -m pytest -m "unit or integration or e2e or agent or api" -v --tb=short \
      --html="$REPORT_DIR/full-report.html" --self-contained-html
    ;;

  *)
    echo "Unknown suite: $SUITE"
    echo "Usage: $0 [unit|integration|e2e|all]"
    exit 1
    ;;
esac

echo ""
echo "Report: $REPORT_DIR/"
