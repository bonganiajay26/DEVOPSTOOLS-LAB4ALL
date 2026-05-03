# Quarterly Incident Response Drill Guide

> At VersatileCommerce, quarterly drills reduced MTTR by 60% for known incident patterns.
> Engineers know the playbook under pressure because they've practiced it.

---

## Why Run Drills?

```
Without drills:
  Engineer gets paged at 3 AM
  → Reads the runbook for the first time (under pressure)
  → Takes 20 min to remember how to query Prometheus
  → Forgot the rollback command needs --to-revision flag

With drills:
  Engineer gets paged at 3 AM
  → Runs familiar script, done in 8 min
  → Rollback is muscle memory
  → Runbook verified accurate BEFORE the real incident
```

---

## Drill Schedule

```
Q1: Database failure scenario (+ backup/restore)
Q2: Bad deployment scenario (+ rollback automation)
Q3: Traffic spike scenario (+ auto-scaling validation)
Q4: Multi-service cascade failure (+ communication drill)
```

---

## How to Run a Drill

### Before the drill (1 day before)
```
□ Select scenario (see scenarios/ folder)
□ Notify: "GameDay drill [DATE] [TIME] — [SCENARIO DESCRIPTION]"
□ Assign: IC, Tech Lead, Comms Lead, Observer
□ Prepare the failure injection (do NOT tell responders what will fail)
□ Set up a staging environment or use chaos engineering in prod (with safeguards)
```

### During the drill
```
□ Observer watches and takes notes (does NOT help)
□ IC runs the playbook as if it were real
□ Timer: measure MTTD, MTTA, MTTR
□ Record: every command run, every hypothesis, every decision
□ Debrief: 30 min after resolution
```

### After the drill (debrief)
```
□ What worked?
□ What was slow or confusing?
□ Were the runbooks accurate?
□ Update runbooks with findings
□ Update scripts with improvements
□ Assign: "fix runbook X" as action item before next drill
```

---

## Drill Scenario 1: Bad Deployment

**Setup (done by drill organizer, hidden from responders):**
```bash
# Deploy a version that causes a 15% error rate
cat > bad-deployment-patch.yaml << 'EOF'
spec:
  template:
    spec:
      containers:
      - name: api
        env:
        - name: SIMULATE_ERROR_RATE
          value: "0.15"   # app returns 15% 500s when this is set
EOF
kubectl patch deployment api-service -n staging \
  --patch-file bad-deployment-patch.yaml
```

**What responders should do:**
1. Detect via Prometheus alert
2. Declare incident
3. Measure blast radius
4. Check deployment history → find the recent deploy
5. Rollback → verify error rate drops
6. All-clear

**Success criteria:**
- Alert fired within 2 minutes of deployment
- Rollback completed within 10 minutes
- Zero data loss, no user-visible data corruption

---

## Drill Scenario 2: Database Slowdown

**Setup:**
```bash
# Inject slow queries via pg_sleep in a background job
kubectl exec -it postgres-0 -n staging-database -- \
  psql -U postgres -c "
    SELECT pg_sleep(30)
    FROM generate_series(1, 5);" &   # Creates 5 blocking connections
```

**What responders should do:**
1. Detect via high latency alert
2. Trace the slowdown using distributed tracing (Jaeger)
3. Find long-running queries in pg_stat_activity
4. Kill the offending queries
5. Verify latency returns to normal

---

## Drill Scenario 3: Certificate Expired

**Setup:**
```bash
# Create a cert that expires in 1 minute (for drill)
# Use cert-manager to create an ultra-short-lived cert
kubectl apply -f - << 'EOF'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: drill-expired-cert
  namespace: staging
spec:
  secretName: drill-expired-cert-tls
  duration: 1m    # Expires in 1 minute
  dnsNames: ["drill.staging.company.com"]
  issuerRef:
    name: selfsigned-issuer
    kind: Issuer
EOF
```

---

## Measuring Drill Performance

```python
# After each drill, record metrics
drill_metrics = {
    "date": "2024-01-15",
    "scenario": "bad-deployment",
    "team": "platform",
    "mttd_minutes": 1.5,    # Alert fired 1.5 min after injection
    "mtta_minutes": 2.0,    # Ack'd 2 min after alert
    "mttm_minutes": 8.0,    # Mitigation applied 8 min after declaration
    "mttr_minutes": 12.0,   # Resolved 12 min after declaration
    "runbook_accurate": True,
    "rollback_used": True,
    "issues_found": [
        "Rollback script didn't handle StatefulSets",
        "Prometheus query in runbook had wrong label"
    ],
    "action_items": [
        "Fix rollback script for StatefulSets",
        "Update Prometheus query in runbook 05"
    ]
}
```

---

## Drill Retrospective Questions

```
1. How long did it take to identify the root cause?
   Target: < 10 min for known patterns

2. Was the runbook helpful? Did it have what you needed?
   If no: update it immediately while memory is fresh

3. Were the right people available?
   If no: update on-call rotation or escalation contacts

4. Was there anything that slowed you down?
   Missing tool? Wrong permissions? Confusing script?

5. What would have made this faster?
   → These become your highest-priority action items
```

---

## Drill Anti-Patterns to Avoid

```
❌ "Let's skip the drill this quarter, we're too busy"
   → The next real incident will take 4 hours instead of 20 min

❌ "Everyone knows what to do"
   → Knowledge without practice degrades. Drills = practice.

❌ Running drills in production without safeguards
   → Use staging or use chaos engineering with circuit breakers

❌ Not updating runbooks after the drill
   → The point of the drill was to find inaccuracies

❌ Only senior engineers drill
   → Junior engineers go on-call too. They need practice most.
```
