#!/usr/bin/env bash
# Validate Datadog Agent health — run after every install or config change
set -euo pipefail

echo "=== Datadog Agent Validation ==="

# 1. Agent running
echo -n "[1] Agent process... "
if systemctl is-active --quiet datadog-agent; then
  echo "OK"
else
  echo "FAIL — run: sudo systemctl start datadog-agent"
  exit 1
fi

# 2. API key valid
echo -n "[2] API key... "
STATUS=$(sudo datadog-agent status 2>&1)
if echo "$STATUS" | grep -q "API Key valid"; then
  echo "OK"
else
  echo "FAIL — check DD_API_KEY in /etc/datadog-agent/datadog.yaml"
fi

# 3. Network connectivity
echo -n "[3] Connectivity to Datadog... "
if curl -sf -o /dev/null "https://app.datadoghq.com"; then
  echo "OK"
else
  echo "FAIL — check firewall rules (443 outbound to *.datadoghq.com)"
fi

# 4. Logs enabled
echo -n "[4] Log collection... "
if sudo datadog-agent status 2>&1 | grep -q "Logs Agent"; then
  echo "OK"
else
  echo "FAIL — set logs_enabled: true in datadog.yaml"
fi

# 5. APM enabled
echo -n "[5] APM agent... "
if sudo datadog-agent status 2>&1 | grep -q "APM Agent"; then
  echo "OK"
else
  echo "FAIL — set apm_config.enabled: true in datadog.yaml"
fi

# 6. Clock drift
echo -n "[6] Clock drift... "
DRIFT=$(sudo datadog-agent status 2>&1 | grep -i "offset" | awk '{print $NF}' | tr -d 'ms' || echo "0")
if [ "${DRIFT%.*}" -lt 10 ] 2>/dev/null; then
  echo "OK (${DRIFT})"
else
  echo "WARN — drift may cause metric timestamp issues (sync NTP)"
fi

echo ""
echo "=== Full status ==="
sudo datadog-agent status
