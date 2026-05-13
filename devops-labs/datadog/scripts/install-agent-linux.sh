#!/usr/bin/env bash
# Install Datadog Agent 7 on Linux
# Usage: DD_API_KEY=your_key DD_TAGS="env:production team:platform" bash install-agent-linux.sh
set -euo pipefail

: "${DD_API_KEY:?DD_API_KEY is required}"

DD_SITE="${DD_SITE:-datadoghq.com}"
DD_TAGS="${DD_TAGS:-env:production}"

echo "Installing Datadog Agent 7..."
DD_API_KEY="$DD_API_KEY" \
DD_SITE="$DD_SITE" \
DD_TAGS="$DD_TAGS" \
  bash -c "$(curl -L https://install.datadoghq.com/scripts/install_script_agent7.sh)"

echo "Enabling log collection..."
sudo sed -i 's/# logs_enabled: false/logs_enabled: true/' /etc/datadog-agent/datadog.yaml

echo "Restarting agent..."
sudo systemctl restart datadog-agent

echo "Waiting for agent to start..."
sleep 5

echo "Validating..."
sudo datadog-agent status | grep -E "API Key|Logs Agent|APM Agent"

echo ""
echo "Done. Agent is running."
