# AIOps Interview Questions

## Q1. What is AIOps and what problems does it solve?

```
AIOps = AI/ML applied to IT operations data (metrics, logs, events, traces)

Problems solved:
1. Alert fatigue: 1000 alerts → 1 incident notification
2. Slow MTTD: humans notice issues in minutes, ML detects in seconds
3. Reactive ops: predict failures before they happen
4. Manual RCA: AI correlates symptoms to root cause faster
5. Repetitive toil: automate known remediation actions

Real ROI examples:
  - MTTD: 15 min → 30 seconds (anomaly detection)
  - MTTR: 45 min → 8 min (AI root cause + automated remediation)
  - Alert noise: 10,000/week → 50 actionable incidents
```

---

## Q2. How does anomaly detection work for metrics?

```
Methods from simple to complex:

1. Static thresholds (not AI, but common)
   CPU > 80% → alert
   Problem: doesn't account for time-of-day patterns

2. Dynamic baselines (moving average ± N stddev)
   Alert if current > mean(last 7 days) + 3σ
   Better, but doesn't handle seasonality

3. Prophet (time series forecasting)
   Learns weekly/daily patterns
   Predicts expected value + confidence interval
   Alert if actual >> upper bound
   Best for: request rate, latency, business metrics

4. Isolation Forest (unsupervised ML)
   Detects outliers in multi-dimensional metric space
   Good for: correlating multiple metrics simultaneously

5. LSTM/Transformer (deep learning)
   Learns complex temporal patterns
   Best for: complex infrastructure with many interacting metrics
   Overkill for most use cases
```

---

## Q3. How do you implement log anomaly detection?

```
Approaches:
1. Keyword matching (regex) — fragile, needs updating
2. Log clustering (Drain3, SPELL) — detect new/rare log patterns
3. Log embedding + ML — semantic similarity
4. Count-based — alert on unusual volume of error logs

Log clustering with Drain3:
- Parse logs into templates ("User X logged in" → "User * logged in")
- Cluster similar templates
- Track template frequency
- Alert on: new templates (unknown behavior) + volume spikes (known error surging)

Production implementation:
  Fluentd → Kafka → Python processor (Drain3) → Anomaly score → Alertmanager

Key metric: "new template rate" per hour
  Baseline: 2-3 new templates/hour (normal)
  Spike: 20+ new templates → something changed (deploy? attack?)
```

---

## Q4. What is intelligent alert correlation and why is it important?

```
Without correlation:
  DB runs slow → 500 alerts fire (each pod, each endpoint, each service)
  On-call gets 500 pages at 3AM
  
With correlation:
  500 alerts → 1 incident "DB slowdown causing cascade"
  On-call gets 1 page with full context

Correlation methods:

1. Temporal: alerts within same 5-minute window → group
2. Topological: service dependency graph → alerts in same subtree → group
3. Symptom-cause: "DB connection errors" + "HTTP 503s" → same incident
4. Root cause analysis: ML model predicts which alert is the cause

Tools:
  PagerDuty Event Intelligence — AI-based correlation
  BigPanda — topology-aware correlation
  Moogsoft — ML-based incident management
  Build your own: AlertCorrelator class (see docs/01-concepts.md)
```

---

## Q5. How do you build a Slack bot for incident management with LLMs?

```python
# Slack bot that:
# 1. Receives PagerDuty alerts via webhook
# 2. Fetches context (logs, metrics, recent deploys)
# 3. Calls Claude API for initial diagnosis
# 4. Posts analysis to incident channel
# 5. Can execute runbook commands when instructed

from slack_bolt import App
import anthropic

app = App(token=os.environ["SLACK_BOT_TOKEN"])
claude = anthropic.Anthropic()

@app.event("app_mention")
def handle_mention(event, say, client):
    user_question = event['text']
    channel = event['channel']
    
    # Gather context
    context = gather_incident_context(channel)
    
    # Ask Claude
    response = claude.messages.create(
        model="claude-opus-4-5",
        max_tokens=2048,
        tools=[
            {
                "name": "kubectl_command",
                "description": "Run a read-only kubectl command",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "command": {"type": "string",
                                   "description": "kubectl command (read-only only)"}
                    }
                }
            }
        ],
        messages=[{
            "role": "user",
            "content": f"Context:\n{context}\n\nQuestion: {user_question}"
        }]
    )
    
    # Handle tool calls (Claude wants to run kubectl)
    if response.stop_reason == "tool_use":
        for block in response.content:
            if block.type == "tool_use" and block.name == "kubectl_command":
                # Validate it's read-only
                cmd = block.input["command"]
                if any(w in cmd for w in ["delete", "apply", "edit", "patch"]):
                    say("⚠️ I can only run read-only commands")
                    continue
                result = subprocess.run(cmd.split(), capture_output=True, text=True)
                # Continue conversation with tool result...
    
    say(response.content[0].text)
```

---

## Q6. How do you predict infrastructure failures before they happen?

```
Predictive failure scenarios:

1. Disk exhaustion (linear regression)
   Train on: disk usage over time
   Predict: when will disk reach 90%
   Alert: 24 hours before
   
2. Memory leak (regression on RSS over uptime)
   Train on: memory usage vs process uptime
   Detect: if memory grows linearly with time → leak
   Alert: N hours before OOM
   
3. Cascade failure (graph neural network)
   Model: service dependency graph
   Input: current health of each service
   Predict: probability of cascade in next 30 min
   
4. Hardware failure (survival analysis)
   Train on: SMART disk metrics before failures
   Predict: probability of disk failure in next 7 days
   Alert: Pre-emptively migrate data
   
Feature engineering for failure prediction:
   - Rolling statistics (mean, stddev, trend over 1h, 6h, 24h)
   - Change point detection (when did pattern change?)
   - Rate of change (second derivative — is it accelerating?)
   - Cross-metric correlations (CPU spike + latency spike = different from just CPU spike)
```

---

## Q7. What is the role of a Knowledge Graph in AIOps?

```
Knowledge Graph = topology map of your infrastructure + relationships

Nodes:
  Services, pods, nodes, databases, load balancers, users, deployments

Edges:
  "api-service calls postgres"
  "api-service depends on redis"
  "pod-abc runs on node-1"
  "deployment-v1.2.3 deployed at 14:00"

Uses in AIOps:
  1. Alert correlation: trace alerts through service graph to find root
  2. Impact analysis: if postgres fails, what services are affected?
  3. Change correlation: which service changed just before the incident?
  4. Automated runbooks: "for postgres issues, page DB team"

Implementation:
  Neo4j (graph database) or Amazon Neptune
  Populate from: kubectl (pods/nodes), service mesh (calls), CMDB
  Query: Cypher (Neo4j) or SPARQL

Example query:
  MATCH (service)-[:CALLS]->(db:Database)
  WHERE db.name = 'postgres'
  RETURN service.name    # All services that use postgres
  # → notify all affected teams when postgres has issues
```

---

## Q8. How do you evaluate whether your AIOps solution is working?

```python
# Metrics for AIOps effectiveness

evaluation_metrics = {
    # Alert quality
    "alert_reduction_rate": "alerts_after / alerts_before",
    # Target: > 80% reduction in noise
    
    "alert_precision": "true_incidents / total_alerts_sent",
    # Target: > 90% (most alerts are real)
    
    "alert_recall": "detected_incidents / total_incidents",
    # Target: > 99% (don't miss real incidents)
    
    # Time-to-detect
    "MTTD_improvement": "(old_MTTD - new_MTTD) / old_MTTD",
    # Target: > 50% improvement
    
    # Anomaly detection
    "anomaly_detection_lead_time_minutes": "how early did we detect vs user reports",
    # Target: > 5 minutes before user impact
    
    "false_positive_rate": "false_alarms / total_anomalies_detected",
    # Target: < 10% (oncall trust the alerts)
    
    # Auto-remediation
    "remediation_success_rate": "successful_auto_fixes / total_attempts",
    # Target: > 95%
    
    "remediation_toil_eliminated_hours_per_week": "measure before/after",
}

# Evaluation process:
# 1. A/B test: 50% incidents to AIOps-enhanced pipeline, 50% traditional
# 2. Measure: MTTD, MTTR, alert volume, on-call interruptions
# 3. Adjust: tune sensitivity to balance precision vs recall
```

---

## Q9. Explain SIEM integration with AIOps.

```
SIEM (Security Information and Event Management):
  Collects security events, correlates threats
  Tools: Splunk, IBM QRadar, Microsoft Sentinel, Elastic SIEM

AIOps + SIEM integration:
  Combine operational + security signals
  Example: high CPU (operational) + unusual network traffic (security) = possible cryptominer

Integration patterns:
  1. Shared data lake: metrics + security events → unified ML
  2. Bidirectional enrichment: security alert with infra context
     "Pod X has unusual outbound connections" → AIOps provides:
     - Which team owns pod X?
     - What changed recently?
     - Is this a known pattern?

Kubernetes security events to monitor:
  - Unauthorized API calls (audit logs)
  - Container escape attempts (Falco)
  - Unusual service account usage
  - Image pulls from unknown registries
  - Network connection to suspicious IPs

# Feed Falco alerts to AIOps correlation engine:
# Falco → Kafka → ML correlation → PagerDuty + Slack + JIRA
```

---

## Q10. What is the difference between reactive, proactive, and predictive AIOps?

```
Reactive AIOps:
  - Detects incidents after they happen
  - Correlates alerts → single incident
  - Suggests root cause
  - Automates remediation
  Example: "DB is down, here's the blast radius, run this runbook"

Proactive AIOps:
  - Detects anomalies early (before user impact)
  - Acts on weak signals before threshold breaches
  - "Request latency trending up" → alert before it exceeds SLO
  Example: "Latency increased 20% in last hour, watch out"

Predictive AIOps:
  - Predicts failures before any symptoms
  - Uses historical failure patterns
  - "This disk pattern matches 90% of disks that failed in the past"
  Example: "Node will have OOM in 6 hours based on memory growth trend"

Maturity:
  Reactive → Proactive → Predictive → Autonomous (full self-healing)
  Most orgs are between Reactive and Proactive
```

---

## Q11. How do you implement root cause analysis (RCA) automation?

```python
# Causal inference approach to RCA

def automated_rca(incident: dict, topology: dict, metrics: pd.DataFrame) -> dict:
    """
    Given an incident, work backward through the service graph
    to find the most likely root cause.
    """
    affected_services = incident['affected_services']
    incident_time = incident['start_time']

    # Step 1: Find services that changed BEFORE the incident
    recent_changes = get_changes_before(incident_time, window_minutes=30)
    # Deployments, config changes, scale events

    # Step 2: Find services with first anomaly (earliest symptom)
    service_anomaly_times = {}
    for service in affected_services:
        metrics_data = metrics[
            (metrics['service'] == service) &
            (metrics['timestamp'] > incident_time - timedelta(minutes=30))
        ]
        first_anomaly = detect_first_anomaly(metrics_data)
        if first_anomaly:
            service_anomaly_times[service] = first_anomaly

    root_cause_candidates = sorted(service_anomaly_times, key=service_anomaly_times.get)

    # Step 3: Check service dependencies (upstream service failing first = root cause)
    dependency_graph = topology.get('service_dependencies', {})
    # Walk upstream from affected services

    # Step 4: Correlate with recent changes
    changed_services = {c['service'] for c in recent_changes}

    final_hypothesis = {
        "primary_suspect": root_cause_candidates[0] if root_cause_candidates else "unknown",
        "evidence": {
            "first_anomaly": service_anomaly_times,
            "recent_changes": recent_changes,
            "changed_and_affected": changed_services & set(affected_services)
        },
        "confidence": 0.8 if root_cause_candidates[0] in changed_services else 0.4,
        "recommended_action": get_runbook(root_cause_candidates[0])
    }

    return final_hypothesis
```

---

## Q12. How do you implement AIOps with open-source tools?

```
Full open-source AIOps stack:

Data Collection:
  Prometheus → metrics
  Loki → logs
  Tempo → traces
  Kubernetes Events → events

Processing:
  Apache Kafka → real-time event streaming
  Apache Flink → stream processing for anomaly detection

ML Layer:
  Prophet → time series anomaly detection
  Drain3 → log clustering
  PyOD → unsupervised anomaly detection
  Custom models → RCA, failure prediction

Storage:
  TimescaleDB → metrics long-term
  Elasticsearch → log analytics
  Neo4j → topology/knowledge graph

Automation:
  Python + Kubernetes SDK → auto-remediation
  n8n → workflow automation
  Slack API → incident communication

Dashboards:
  Grafana → operational + ML dashboards
  Kibana → log analysis

Cost:
  Infrastructure: ~$500-1000/month for mid-size platform
  vs Commercial (Datadog, Dynatrace): $5000-50000/month
```

---

## Q13. What are the challenges of AIOps in production?

```
Challenge 1: Data quality
  ML models are only as good as the data
  Missing metrics, inconsistent labels, gaps in data
  Solution: data validation pipeline, monitoring for metric gaps

Challenge 2: Model drift
  Infrastructure changes (migration, new services) break models
  What was "normal" before is different after
  Solution: periodic retraining, drift detection on anomaly rate

Challenge 3: Trust and adoption
  On-call engineers don't trust AI alerts initially
  Too many false positives = ignored alerts
  Solution: start conservative, tune sensitivity, show value

Challenge 4: Coverage
  Not all failures fit the pattern
  Novel failures (never seen before) won't be predicted
  Solution: AI augments, not replaces, human judgment

Challenge 5: Explainability
  "Why did the AI flag this?" must have a clear answer
  Black-box models frustrate engineers
  Solution: use interpretable models where possible, add explanations

Challenge 6: Kubernetes dynamic nature
  Pods start/stop constantly → topology changes constantly
  Training data has changing feature space
  Solution: entity-based features (service-level, not pod-level)
```

---

## Q14. How do you integrate AIOps with ChatOps?

```python
# ChatOps = managing operations through chat (Slack/Teams)
# AIOps + ChatOps = AI assistant in your ops channel

# Workflow:
# 1. Alert fires → Slack incident channel created automatically
# 2. AI bot joins → posts initial diagnosis
# 3. Engineer investigates → asks bot questions
# 4. Bot can run read-only commands (kubectl get, metrics queries)
# 5. Engineer decides to rollback → asks bot to do it (with approval)
# 6. Bot executes with full audit trail in Slack thread

# Example Slack interaction:
# Bot: "🚨 Incident: API error rate 5% (SLO: 0.1%). Most likely cause:
#       Deployment api-service v2.3.1 at 14:00. Recommend rollback."
#
# Engineer: "@ops-bot what's the current error breakdown by endpoint?"
# Bot: [runs kubectl + prometheus query] "Top errors:
#       POST /api/checkout: 42% error rate
#       GET /api/cart: 8% error rate"
#
# Engineer: "@ops-bot rollback api-service to previous version"
# Bot: "I'll rollback api-service to v2.3.0. Type 'confirm rollback' to proceed"
# Engineer: "confirm rollback"
# Bot: "✅ Rolling back... Done. Error rate back to 0.01%"

# Key principle: AI recommends, human confirms for destructive actions
```

---

## Q15. What is the future of AIOps?

```
Near term (1-2 years):
  - LLM-powered runbooks (describe problem, get specific commands)
  - Autonomous root cause with confidence scores
  - Self-healing infrastructure for common failure modes
  - AI-assisted post-mortems (auto-draft timeline + contributing factors)

Medium term (2-5 years):
  - Full autonomous remediation for well-understood failure classes
  - Predictive capacity planning with high accuracy
  - Cross-org incident correlation (your vendor is having issues)
  - Natural language infrastructure querying ("what changed in the last hour?")

Long term:
  - Largely autonomous operations for routine issues
  - Humans focus on novel problems and architectural decisions
  - Continuous optimization of SLOs/cost/performance automatically

Current state at leading companies:
  Google/Meta: 80% of alerts are handled without human intervention
  Large cloud providers: predictive maintenance for hardware
  Financial services: real-time fraud detection with automated response

The SRE role evolves:
  From: "fix things when they break"
  To:   "build systems that fix themselves"
       "improve the AI that manages the infrastructure"
       "handle novel, high-stakes situations humans must own"
```
