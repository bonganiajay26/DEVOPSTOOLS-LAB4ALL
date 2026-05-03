# OOMKilled — Complete Debug & Remediation Guide

> **Real methodology used in production.** Covers diagnosis, root cause differentiation,
> Prometheus alerting, VPA right-sizing, and a live demo you can run in kind.

---

## What Is OOMKilled?

```
Exit Code 137 = SIGKILL sent by the Linux kernel OOM (Out-Of-Memory) killer.

The container exceeded its memory LIMIT.
The kernel killed it — no warning, no graceful shutdown.

memory.limit_in_bytes (cgroup)
        │
        │  container keeps allocating...
        │
        ▼
  ██████████████████░░  → 90%
  ████████████████████  → 100%  ← cgroup limit hit
  OOM killer fires: SIGKILL → exit code 137
```

---

## Folder Structure

```
oomkilled-debug/
├── README.md                        ← This file (full methodology)
├── scripts/
│   ├── 01-diagnose.sh               ← Step-by-step diagnosis commands
│   ├── 02-memory-profile.sh         ← Live memory analysis
│   ├── 03-goldilocks-setup.sh       ← VPA + Goldilocks installation
│   └── 04-rightsize.sh              ← Apply VPA recommendations
├── manifests/
│   ├── demo-memory-leak.yaml        ← Intentional OOMKill demo app
│   ├── vpa-recommendation.yaml      ← VPA in recommendation mode
│   ├── vpa-auto.yaml                ← VPA in auto mode (non-stateful)
│   └── goldilocks-namespace.yaml    ← Enable Goldilocks per namespace
├── prometheus/
│   ├── oom-alert-rules.yaml         ← PrometheusRule: OOM alerts
│   └── memory-recording-rules.yaml  ← Pre-computed memory metrics
├── grafana/
│   └── oom-dashboard.json           ← Grafana dashboard: memory trends
└── demo-app/
    ├── app.py                       ← Python app with /leak endpoint
    ├── Dockerfile
    └── requirements.txt
```

---

## 5-Step Debug Methodology

### STEP 1 — Confirm OOMKill (30 seconds)

```bash
# Confirm exit code 137 and OOMKilled reason
kubectl describe pod <pod-name> -n <namespace>

# Look for this in the output:
# Last State:     Terminated
#   Reason:       OOMKilled          ← confirmed
#   Exit Code:    137                ← SIGKILL from kernel
#   Started:      Mon, 15 Jan 2024 14:22:01
#   Finished:     Mon, 15 Jan 2024 14:22:45

# Also check the Limits:
# Limits:
#   memory:  256Mi    ← this is what the container is being killed at

# And Events section:
# Warning  OOMKilling  kubelet  Memory cgroup out of memory:
#          Kill process 12345 (python3) total-vm:524288kB,
#          anon-rss:261120kB, file-rss:4096kB
```

### STEP 2 — Current Memory Usage

```bash
# Current usage (requires metrics-server)
kubectl top pod <pod-name> -n <namespace>
kubectl top pod <pod-name> -n <namespace> --containers

# Example output:
# NAME          CPU(cores)   MEMORY(bytes)
# myapp-abc123  45m          248Mi         ← dangerously close to 256Mi limit!

# Compare: if usage ≈ limit → it will OOMKill again soon
```

### STEP 3 — Memory Pattern (Is it a leak or a spike?)

```bash
# Via Prometheus (port-forward if needed):
kubectl port-forward svc/prometheus-operated 9090:9090 -n monitoring &

# Query: memory trend over 24h
# container_memory_working_set_bytes{pod="<pod>", container="<container>"}

# LEAK pattern:    ↗↗↗↗↗↗↗  (steady increase over hours/days)
# SPIKE pattern:   _____|‾|___  (sudden jump then drop or kill)
# NORMAL pattern:  ~~~~~~~~~~~  (stable with minor fluctuation)
```

### STEP 4 — Application Logs Before the Kill

```bash
# Logs from the container that just died
kubectl logs <pod-name> -n <namespace> --previous

# Look for:
# Python:  MemoryError, malloc failed
# Java:    java.lang.OutOfMemoryError: Java heap space
#          GC overhead limit exceeded
# Node.js: FATAL ERROR: CALL_AND_RETRY_LAST Allocation failed
# Go:      runtime: out of memory
# Generic: cannot allocate memory

# Time-travel: logs from specific time window
kubectl logs <pod-name> -n <namespace> --previous \
  --since-time="2024-01-15T14:20:00Z"
```

### STEP 5 — Root Cause + Fix

```
ROOT CAUSE A: MEMORY LEAK (gradual increase over time)
  Evidence: Prometheus graph shows memory growing 5-10MB/hour
            App runs fine for hours then crashes
  Fix:      1. Profile the app (find the leak)
            2. Temporarily: increase limit + set OOM alert at 80%
            3. Long-term: fix the leak in code

ROOT CAUSE B: LEGITIMATE LOAD SPIKE (limit is too low)
  Evidence: Memory spikes correlated with traffic peaks
            Memory returns to baseline after spike
  Fix:      1. Increase memory limit to observed p99 + 20% headroom
            2. Add HPA to spread load across more pods
            3. Use VPA recommendation for right-sizing

ROOT CAUSE C: WRONG INITIAL LIMIT (misconfigured)
  Evidence: App OOMKills almost immediately on startup
            Limit is very low (e.g., 64Mi for a JVM app)
  Fix:      1. Use VPA in recommendation mode for 24h
            2. Apply recommended limits
            3. Use Goldilocks UI for visual right-sizing
```

---

## Quick Reference: Memory Metrics

```promql
# Current working set memory (what K8s uses for OOM decisions)
container_memory_working_set_bytes{namespace="production", container!=""}

# Memory as % of limit
container_memory_working_set_bytes
  / container_spec_memory_limit_bytes * 100

# OOM events in last hour
increase(kube_pod_container_status_restarts_total[1h])

# Pods approaching limit (> 80%)
(
  container_memory_working_set_bytes
  / container_spec_memory_limit_bytes
) > 0.80

# Memory growth rate (leak detector)
deriv(container_memory_working_set_bytes[30m])
```

---

## Goldilocks (Fairwinds) — Visual Right-Sizing

Goldilocks runs VPA in recommendation mode for all deployments in
labelled namespaces and provides a web UI showing:

```
Deployment: myapp
Container:  api

              Current    Recommended (Burstable)  Recommended (Guaranteed)
  CPU req:    100m       45m                      45m
  CPU lim:    500m       200m                     45m
  Mem req:    128Mi      156Mi                    156Mi
  Mem lim:    256Mi      312Mi       ← SET THIS   156Mi
```

Setup: see `scripts/03-goldilocks-setup.sh`

---

## Prevention Checklist

```
□ Set BOTH requests and limits on every container
□ requests = typical usage (p50)
□ limits   = observed p99 + 20% headroom
□ Alert at 80% of limit (not 100% — too late by then)
□ VPA in recommendation mode for all production workloads
□ Goldilocks UI for visual review during deployments
□ Memory leak test in staging: run load test for 2h, check growth
□ JVM: set -Xmx to 70% of container limit (leave headroom for native)
□ Node.js: set --max-old-space-size to 75% of container limit
□ Add /metrics endpoint exposing process_resident_memory_bytes
```
