#!/bin/bash
# =============================================================
# Script 01 — Declare Incident
# Creates Slack channel, posts declaration, updates status page
# Usage:
#   bash 01-declare-incident.sh \
#     --severity SEV1 \
#     --title "Payment API 503s" \
#     --service payment-api \
#     --ic "alice"
# =============================================================

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────
SEVERITY=""
TITLE=""
SERVICE=""
IC="${IC_NAME:-$(git config user.name 2>/dev/null || echo 'on-call')}"
SLACK_TOKEN="${SLACK_BOT_TOKEN:-}"
SLACK_CHANNEL_PREFIX="inc"
PD_TOKEN="${PAGERDUTY_API_TOKEN:-}"
STATUSPAGE_API_KEY="${STATUSPAGE_API_KEY:-}"
STATUSPAGE_PAGE_ID="${STATUSPAGE_PAGE_ID:-}"

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Parse arguments ───────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --severity) SEVERITY="$2"; shift 2 ;;
    --title)    TITLE="$2";    shift 2 ;;
    --service)  SERVICE="$2";  shift 2 ;;
    --ic)       IC="$2";       shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [ -z "$SEVERITY" ] || [ -z "$TITLE" ]; then
  echo "Usage: $0 --severity SEV1|SEV2|SEV3 --title 'description' [--service name] [--ic name]"
  exit 1
fi

TIMESTAMP=$(date -u '+%Y%m%d-%H%M')
DATE_SHORT=$(date -u '+%Y-%m-%d')
TIME_UTC=$(date -u '+%H:%M UTC')

# Normalize title for channel name (lowercase, hyphens)
CHANNEL_SUFFIX=$(echo "$TITLE" | tr '[:upper:]' '[:lower:]' | \
  sed 's/[^a-z0-9 ]//g' | tr ' ' '-' | cut -c1-40)
CHANNEL_NAME="${SLACK_CHANNEL_PREFIX}-${DATE_SHORT}-${CHANNEL_SUFFIX}"

echo ""
echo -e "${BOLD}${RED}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${RED}║   INCIDENT DECLARED: $SEVERITY               ${NC}"
echo -e "${BOLD}${RED}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo "  Channel:   #${CHANNEL_NAME}"
echo "  Severity:  ${SEVERITY}"
echo "  Title:     ${TITLE}"
echo "  Service:   ${SERVICE:-unknown}"
echo "  IC:        ${IC}"
echo "  Time:      ${TIME_UTC}"
echo ""

# ── Severity config ───────────────────────────────────────────
case "$SEVERITY" in
  SEV1)
    EMOJI=":red_circle:"
    URGENCY="CRITICAL — All hands"
    NOTIFY_GROUPS="@sre-team @oncall-lead"
    RESPONSE_TIME="5 min ACK"
    ;;
  SEV2)
    EMOJI=":large_orange_circle:"
    URGENCY="HIGH — On-call responds"
    NOTIFY_GROUPS="@oncall-primary"
    RESPONSE_TIME="15 min ACK"
    ;;
  SEV3)
    EMOJI=":large_yellow_circle:"
    URGENCY="MEDIUM — Business hours"
    NOTIFY_GROUPS="@oncall-primary"
    RESPONSE_TIME="30 min ACK"
    ;;
esac

# ── Step 1: Create Slack channel ──────────────────────────────
echo "Step 1: Creating Slack channel #${CHANNEL_NAME}..."

if [ -n "$SLACK_TOKEN" ]; then
  CHANNEL_RESPONSE=$(curl -sf \
    -H "Authorization: Bearer $SLACK_TOKEN" \
    -H "Content-Type: application/json" \
    --data "{\"name\":\"${CHANNEL_NAME}\"}" \
    "https://slack.com/api/conversations.create")

  CHANNEL_ID=$(echo "$CHANNEL_RESPONSE" | \
    python3 -c "import json,sys; d=json.load(sys.stdin); print(d['channel']['id'])" 2>/dev/null || echo "")

  if [ -n "$CHANNEL_ID" ]; then
    echo -e "  ${GREEN}Channel created: #${CHANNEL_NAME} (${CHANNEL_ID})${NC}"
  else
    echo -e "  ${YELLOW}Could not create channel via API. Create manually: #${CHANNEL_NAME}${NC}"
  fi
else
  echo -e "  ${YELLOW}SLACK_BOT_TOKEN not set. Create channel manually: #${CHANNEL_NAME}${NC}"
  CHANNEL_ID=""
fi

# ── Step 2: Post incident declaration ─────────────────────────
echo "Step 2: Posting incident declaration..."

DECLARATION_BLOCKS=$(python3 << PYEOF
import json

blocks = [
    {
        "type": "header",
        "text": {
            "type": "plain_text",
            "text": "${EMOJI} ${SEVERITY}: ${TITLE}"
        }
    },
    {
        "type": "section",
        "fields": [
            {"type": "mrkdwn", "text": "*Severity:*\n${SEVERITY} — ${URGENCY}"},
            {"type": "mrkdwn", "text": "*Service:*\n${SERVICE:-unknown}"},
            {"type": "mrkdwn", "text": "*IC:*\n@${IC}"},
            {"type": "mrkdwn", "text": "*Started:*\n${TIME_UTC}"},
            {"type": "mrkdwn", "text": "*Status Page:*\nPENDING UPDATE"},
            {"type": "mrkdwn", "text": "*Response Time:*\n${RESPONSE_TIME}"}
        ]
    },
    {
        "type": "section",
        "text": {
            "type": "mrkdwn",
            "text": "*Roles needed (reply below):*\n• IC: @${IC} ✅\n• Technical Lead: ❓\n• Comms Lead: ❓\n• Scribe: ❓"
        }
    },
    {
        "type": "divider"
    },
    {
        "type": "section",
        "text": {
            "type": "mrkdwn",
            "text": "*Notify:* ${NOTIFY_GROUPS}\n\n*Runbooks:* <https://wiki.company.com/runbooks|Open Runbooks>\n*Grafana:* <https://grafana.company.com/d/prod-overview|Production Overview>\n*Status Page:* <https://status.company.com/admin|Update Status Page>"
        }
    }
]
print(json.dumps(blocks))
PYEOF
)

if [ -n "$SLACK_TOKEN" ] && [ -n "$CHANNEL_ID" ]; then
  curl -sf \
    -H "Authorization: Bearer $SLACK_TOKEN" \
    -H "Content-Type: application/json" \
    --data "{\"channel\":\"${CHANNEL_ID}\",\"blocks\":${DECLARATION_BLOCKS}}" \
    "https://slack.com/api/chat.postMessage" > /dev/null
  echo -e "  ${GREEN}Declaration posted to #${CHANNEL_NAME}${NC}"
else
  echo "  Post this to #${CHANNEL_NAME}:"
  echo ""
  cat << SLACK_MSG
  ${EMOJI} *${SEVERITY}: ${TITLE}*
  Service: ${SERVICE}  |  IC: @${IC}  |  Time: ${TIME_UTC}

  *Roles needed:*
  - IC: @${IC} ✅
  - Technical Lead: ❓
  - Comms Lead: ❓
  - Scribe: ❓

  Notify: ${NOTIFY_GROUPS}
SLACK_MSG
fi

# ── Step 3: Update status page ────────────────────────────────
echo ""
echo "Step 3: Status page update..."

if [ -n "$STATUSPAGE_API_KEY" ] && [ -n "$STATUSPAGE_PAGE_ID" ]; then
  STATUS="investigating"
  BODY_TEXT="We are investigating reports of issues with ${SERVICE:-our service}. Our team is engaged and working to resolve this. We will update every 15 minutes."

  curl -sf \
    -H "Authorization: OAuth $STATUSPAGE_API_KEY" \
    -H "Content-Type: application/json" \
    "https://api.statuspage.io/v1/pages/${STATUSPAGE_PAGE_ID}/incidents" \
    --data "{
      \"incident\": {
        \"name\": \"${TITLE}\",
        \"status\": \"${STATUS}\",
        \"body\": \"${BODY_TEXT}\",
        \"impact_override\": \"$(echo $SEVERITY | tr 'A-Z' 'a-z')\",
        \"deliver_notifications\": true
      }
    }" > /dev/null
  echo -e "  ${GREEN}Status page updated: INVESTIGATING${NC}"
else
  echo -e "  ${YELLOW}STATUSPAGE credentials not set. Update manually:${NC}"
  echo "  Title:  ${TITLE}"
  echo "  Status: Investigating"
  echo "  Body:   We are investigating reports of issues with ${SERVICE:-our service}."
fi

# ── Step 4: Save incident metadata ────────────────────────────
INCIDENT_FILE="/tmp/incident-${TIMESTAMP}.json"
python3 << PYEOF
import json

incident = {
    "channel": "${CHANNEL_NAME}",
    "severity": "${SEVERITY}",
    "title": "${TITLE}",
    "service": "${SERVICE}",
    "ic": "${IC}",
    "declared_at": "${TIME_UTC}",
    "timestamp": "${TIMESTAMP}"
}

with open("${INCIDENT_FILE}", "w") as f:
    json.dump(incident, f, indent=2)

print(f"Incident metadata saved: ${INCIDENT_FILE}")
PYEOF

# ── Summary ───────────────────────────────────────────────────
echo ""
echo -e "${BOLD}=== Incident Declared ===${NC}"
echo ""
echo "  Slack channel: #${CHANNEL_NAME}"
echo "  Status page:   Updated (INVESTIGATING)"
echo ""
echo -e "${BOLD}Next steps:${NC}"
echo "  1. Assign Technical Lead and Comms Lead in the channel"
echo "  2. Run: bash 02-blast-radius.sh --namespace production"
echo "  3. Post first update at: $(date -u -v+15M '+%H:%M UTC' 2>/dev/null || date -u --date='15 minutes' '+%H:%M UTC' 2>/dev/null || echo '(15 min from now)')"
echo ""
echo "  Incident file: ${INCIDENT_FILE}"
