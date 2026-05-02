# Troubleshooting Methodology

## The Scientific Method for Production Issues

```
1. OBSERVE     — What is the symptom?
2. HYPOTHESIZE — What could cause this?
3. TEST        — Gather data to confirm/deny hypothesis
4. CONCLUDE    — Root cause identified?
5. ACT         — Fix, verify, document
6. PREVENT     — How to avoid this next time?
```

**Critical rule: Change ONE thing at a time.** Otherwise you don't know what fixed it.

---

## The 5 Whys

Dig to root cause, not just symptoms.

```
Symptom: API returns 503 errors
  Why? → No healthy pods serving traffic
    Why? → Pods are in CrashLoopBackOff
      Why? → Container exits with code 1
        Why? → Cannot connect to database
          Why? → Database password was rotated but ConfigMap not updated
                 ↑ THIS is the root cause (a process failure)

Fix: Update ConfigMap with new password (tactical)
Prevention: Automate secret rotation sync with External Secrets Operator (strategic)
```

---

## Decision Trees by Symptom

### "Users can't reach the application"

```
Is DNS resolving? (nslookup api.company.com)
  │
  ├── NO → DNS issue (Route53/CoreDNS problem)
  │
  └── YES → Is Load Balancer healthy?
              │
              ├── NO → Check LB target health, security groups
              │
              └── YES → Is Ingress routing correctly?
                          │
                          ├── Check: kubectl describe ingress
                          └── Is backend service healthy?
                               │
                               ├── kubectl get endpoints → Empty?
                               │   → Selector mismatch / no ready pods
                               └── Pods healthy?
                                    └── Check: kubectl get pods, logs
```

### "Application is slow"

```
High latency?
  │
  ├── Is it CPU? (kubectl top pods) → OOM? → Increase limits
  │
  ├── Is it the database? → EXPLAIN ANALYZE slow queries → Add indexes
  │
  ├── Is it external API? → Add timeout, circuit breaker, cache
  │
  ├── Is it N+1 queries? → Add eager loading
  │
  └── Is it connection pool exhaustion? → Increase pool size, add connection timeout
```

### "Deployment is not working"

```
kubectl rollout status shows Pending/Stuck?
  │
  ├── New pods in ImagePullBackOff → Wrong image name/tag or missing imagePullSecret
  │
  ├── New pods in CrashLoopBackOff → Check: kubectl logs --previous
  │
  ├── Readiness probe failing → App not ready, wrong probe path/port
  │
  └── Insufficient resources → Increase requests, or add nodes
```

---

## Data Collection Checklist

When an incident happens, collect this data BEFORE you change anything:

```bash
# ── 1. When did it start? ──────────────────────────────────────
kubectl get events --sort-by=.lastTimestamp -A | tail -30
# Also check: deployment history, git log, cloud provider status

# ── 2. What is the scope? ─────────────────────────────────────
kubectl get pods -A | grep -v Running | grep -v Completed

# ── 3. What do logs say? ──────────────────────────────────────
kubectl logs -l app=affected-app --tail=100 --all-containers 2>/dev/null | grep -iE "error|fatal|panic"

# ── 4. What are the metrics? ──────────────────────────────────
kubectl top nodes
kubectl top pods -A --sort-by=memory | head -20

# ── 5. What changed recently? ─────────────────────────────────
kubectl rollout history deployment -A
git log --oneline --since="2 hours ago"

# ── 6. What do events show? ───────────────────────────────────
kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp
```

---

## Common Exit Codes

| Code | Signal | Meaning | Likely Cause |
|------|--------|---------|-------------|
| 0 | — | Clean exit | Normal shutdown |
| 1 | — | General error | Application error — check logs |
| 2 | — | Misuse of command | Bad arguments/config |
| 127 | — | Command not found | Bad entrypoint/CMD |
| 130 | SIGINT | Ctrl+C | User interrupted |
| 137 | SIGKILL | Killed forcefully | OOMKill or manual kill |
| 139 | SIGSEGV | Segfault | Application bug/memory issue |
| 143 | SIGTERM | Graceful shutdown | Orchestrator termination |

---

## Network Debugging Toolkit

```bash
# Start a debug pod with useful tools
kubectl run netdebug \
  --image=nicolaka/netshoot:latest \
  --rm -it \
  --restart=Never \
  -- /bin/bash

# Inside netshoot:
# DNS test
nslookup my-service.my-namespace.svc.cluster.local

# TCP connectivity
nc -zv postgres.database.svc.cluster.local 5432

# HTTP test
curl -v http://api-service.production.svc.cluster.local/health

# Trace route
mtr api-service.production.svc.cluster.local

# Check listening ports
ss -tlnp

# Check network interfaces
ip addr show
ip route show

# Packet capture (for advanced debugging)
tcpdump -i eth0 port 8080 -w /tmp/capture.pcap
```

---

## Log Analysis Patterns

```bash
# Most common errors in the last hour
kubectl logs -l app=myapp --since=1h 2>/dev/null | \
  grep -iE "error|exception|failed" | \
  sort | uniq -c | sort -rn | head -20

# Count errors per minute (spot the spike)
kubectl logs -l app=myapp --since=1h 2>/dev/null | \
  grep ERROR | \
  awk '{print $1, $2}' | \
  cut -d: -f1-2 | \
  sort | uniq -c

# Follow logs from all pods simultaneously
kubectl logs -l app=myapp -f --all-containers --max-log-requests=10 2>/dev/null

# Filter for specific transaction
kubectl logs -l app=myapp --since=1h 2>/dev/null | \
  grep "transaction-id-abc123"

# Look for memory/OOM in system logs (on a node)
dmesg | grep -iE "oom|killed|out of memory" | tail -20
```

---

## Systematic Root Cause Analysis Framework

```
P → Problem statement (one sentence)
A → Analysis (what data did you collect?)
F → Findings (what does the data tell you?)
S → Solution (what did you do?)
V → Verification (how did you confirm it worked?)
P → Prevention (what prevents this next time?)

EXAMPLE:
P: API returning 503 errors, started at 14:32 UTC
A: Checked pods (2/3 running), events (OOMKilled), logs (no errors before kill), metrics (memory 480MB/256MB limit)
F: Two pods OOMKilled due to memory limit (256Mi) being too low after deploy added new in-memory cache
S: Increased memory limit to 512Mi in deployment spec
V: Error rate dropped to 0% within 2 minutes of pods restarting
P: Added VPA recommendations to deployment process; added memory-per-request load test to staging CI
```
