# Troubleshooting Interview Questions

## Q1. Production API is returning 503 errors. Walk me through your investigation.

```bash
# 1. Triage (2 min): how bad is it?
kubectl get pods -n production | grep -v Running
kubectl get endpoints api-service -n production  # Empty = no backends

# 2. Check recent changes (did someone deploy recently?)
kubectl rollout history deployment/api -n production
git log --oneline --since="1 hour ago"

# 3. Pod health
kubectl get pods -n production -l app=api
kubectl describe pod <crashing-pod> | grep -A10 Events

# 4. Logs
kubectl logs -l app=api --tail=100 -n production | grep -i error

# 5. Check if it's a network issue
kubectl run nettest --image=curlimages/curl --rm -it -- \
  curl http://api-service.production.svc.cluster.local/health

# If recent deploy → kubectl rollout undo deployment/api -n production
# If OOM → increase memory limit
# If dependency down → check DB/Redis connectivity
# If resource exhaustion → kubectl scale deployment/api --replicas=10
```

---

## Q2. A database migration ran in production and now the app is broken. What do you do?

```bash
# Immediate: reduce blast radius
kubectl scale deployment/api --replicas=0 -n production  # Stop new errors

# Assess: What broke?
kubectl logs -l app=api --tail=100 -n production | grep -i "column\|relation\|syntax\|migration"

# Options:
# A: Migration is backward compatible (added nullable column)
#    → Just rollback the app (migration stays)
kubectl rollout undo deployment/api -n production

# B: Migration is NOT backward compatible (renamed column)
#    → Roll back migration first
kubectl exec -it postgres-0 -n database -- \
  psql -U appuser -d appdb -c "BEGIN; -- run reverse migration SQL; COMMIT;"

# C: Data corruption
#    → Restore from backup (declare major incident)
#    → RDS: restore to point before migration
#    → Postgres: pg_restore from latest backup

# Prevention for future:
# 1. Test migrations on staging with production data snapshot
# 2. Use backward-compatible migrations (expand-then-contract)
# 3. Always have a rollback script prepared
# 4. Deploy migration first, app second (or together with feature flag)
```

---

## Q3. All pods on one node are evicted. What happened?

```bash
# Eviction = node pressure (disk, memory, PID)
kubectl describe node problem-node | grep -A20 "Conditions:"
# DiskPressure: True → disk full
# MemoryPressure: True → RAM full
# PIDPressure: True → too many processes

# For DiskPressure (most common):
kubectl debug node/problem-node -it --image=ubuntu -- df -h
# Is /var/lib/containerd full? (container layers + logs)

# Common causes:
# 1. Container logs not rotated → /var/log full
kubectl exec -it some-pod -- du -sh /var/log/*

# 2. Docker overlay FS filled up
docker system df  # On the node

# Fix:
# Cordon node first (stop new workloads)
kubectl cordon problem-node

# SSH and clean
sudo journalctl --vacuum-size=2G
sudo crictl rmi --prune        # Remove unused images
sudo du -sh /var/lib/containerd/

# After cleanup:
kubectl uncordon problem-node
```

---

## Q4. DNS resolution is failing inside pods. How do you debug?

```bash
# Test DNS
kubectl run dnstest --image=busybox --rm -it -- \
  nslookup postgres.database.svc.cluster.local

# Check CoreDNS pods
kubectl get pods -n kube-system | grep coredns
kubectl logs -n kube-system -l k8s-app=kube-dns

# Common issues:
# 1. CoreDNS pods crashed/restarting
kubectl rollout restart deployment/coredns -n kube-system

# 2. NetworkPolicy blocking DNS
# Pods need UDP/TCP 53 to kube-system
kubectl get networkpolicy -n affected-namespace
# Add DNS egress if missing:
kubectl apply -f - << 'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: affected-namespace
spec:
  podSelector: {}
  egress:
  - ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
EOF

# 3. /etc/resolv.conf misconfigured in pod
kubectl exec my-pod -- cat /etc/resolv.conf
# Should show: nameserver 10.96.0.10 (CoreDNS ClusterIP)

# 4. Search domain missing
# "postgres" doesn't resolve but "postgres.database.svc.cluster.local" does
# → pod's namespace isn't in search path
# Check: kubectl exec pod -- cat /etc/resolv.conf | grep search
```

---

## Q5. Memory usage is high on all nodes. How do you find what's consuming it?

```bash
# Node-level view
kubectl top nodes
kubectl describe node high-mem-node | grep -A20 "Allocated resources"

# Pod-level view
kubectl top pods -A --sort-by=memory | head -20

# Namespace-level view
kubectl top pods -A --sort-by=memory | \
  awk '{print $1,$2,$4}' | \
  sort -k1,1 -k3,3rn

# Container-level (if pod has multiple containers)
kubectl top pod my-pod --containers -n production

# Find pods with no memory limits (could be any size!)
kubectl get pods -A -o json | jq '
  .items[] | select(
    .spec.containers[].resources.limits == null or
    .spec.containers[].resources.limits.memory == null
  ) | .metadata.name'

# For detailed node analysis
kubectl debug node/my-node -it --image=ubuntu -- \
  bash -c "cat /proc/meminfo"

# Action items:
# 1. Set memory limits on all pods (no limits = potential OOM of node)
# 2. Check for memory leaks (pods that grow over time)
# 3. Right-size via VPA recommendations
# 4. Evict low-priority batch workloads during pressure
```

---

## Q6. CI/CD pipeline worked yesterday but fails today. No code changes. What do you check?

```bash
# 1. Infrastructure changes
# - Docker base image updated (:latest → different version)
# - Dependency update from package registry (npm/pip/apt)
# - Runner/agent update

# 2. External dependencies
# - Registry unavailable (pull from DockerHub/GitHub registry)
# - Package not found (npm package removed)
# - Test database down

# 3. Secret/credential rotation
# - AWS IAM key rotated → pipeline has old key
# - Docker registry token expired

# 4. Quota/limit hit
# - GitHub Actions free minutes exhausted
# - ECR storage quota exceeded
# - CodeBuild concurrent build limit

# 5. Permission change
# - Someone changed IAM role permissions
# - Branch protection rule changed

# Debug approach:
# - Compare today's run vs last successful run diff-by-diff
# - Check for "rate limit exceeded" errors in build logs
# - Check registry status pages
# - Check if secrets were rotated (verify credentials manually)

# Prevention:
# - Pin all base image versions (not :latest)
# - Pin all dependency versions (lock files)
# - Set up dependency vulnerability scanning
# - Monitor build success rate as a metric
```

---

## Q7. Application performance degrades after 30 minutes. Restarts fix it. What could it be?

```bash
# Classic memory leak signature
# Collect evidence:
kubectl top pod my-app -n production --no-headers | awk '{print $3}'
# Run this every 5 minutes for an hour → watch memory grow

# Check if memory is growing over pod uptime
kubectl get pod my-pod -n production -o json | \
  jq '.status.containerStatuses[0].state.running.startedAt'

# Memory profiling (Python example):
# Add to app temporarily:
# from memory_profiler import profile
# @profile
# def suspect_function():

# Go pprof:
# kubectl port-forward pod/my-pod 6060:6060
# go tool pprof http://localhost:6060/debug/pprof/heap

# Common causes:
# 1. Object accumulation (cache without TTL)
# 2. Goroutine/thread leak (connections not released)
# 3. Growing in-memory queue (consumer can't keep up)
# 4. File descriptor leak
kubectl exec my-pod -- cat /proc/$(pidof myapp)/status | grep VmRSS

# Short-term fix: add CronJob to restart pod every N hours (NOT a real fix)
# Real fix: find and fix the leak in code

# Check for connection pool leak:
kubectl exec my-pod -- \
  curl http://localhost:8080/debug/metrics | grep "db_connections"
```

---

## Q8. Terraform apply fails with "error acquiring state lock". What do you do?

```bash
# Someone else is running terraform apply, OR a previous run crashed

# Check the lock
aws dynamodb get-item \
  --table-name terraform-state-lock \
  --key '{"LockID":{"S":"my-state-bucket/production/terraform.tfstate-md5"}}'

# If lock is old (from crashed run), force-unlock:
terraform force-unlock LOCK_ID

# Prevent accidental parallel runs:
# Use Terraform Cloud / Atlantis for automatic serialization
# OR: set up CI/CD to use a mutex (GitHub Actions concurrency group)

# In GitHub Actions:
jobs:
  terraform:
    concurrency:
      group: terraform-production
      cancel-in-progress: false  # Queue, don't cancel
```

---

## Q9. Prometheus alerts are firing but the service seems fine. False positive?

```bash
# 1. Check the current metric value
kubectl port-forward svc/prometheus 9090:9090 -n monitoring &
# Open Prometheus UI → check the query

# 2. Compare with alert threshold
# If alert says "CPU > 80%" but actual CPU is 50% → stale alert?

# 3. Check alert "for" clause
# Alert might fire while waiting to resolve (fires for 5m but resolved in 2m)

# 4. Check alert routing (might be receiving old/buffered alert)
kubectl port-forward svc/alertmanager 9093:9093 -n monitoring &
# Check Alertmanager UI → Current Alerts → Last Updated

# 5. Check if metrics-server/node-exporter had issues
kubectl logs -n monitoring -l app=prometheus-node-exporter --tail=50

# 6. Investigate the "for" time
# Alert threshold too sensitive for a metric with high natural variance?
# Solution: increase "for" duration or adjust threshold

# 7. Check time zone issues (UTC vs local time)
# CronJob metrics, business hours alerts

# Resolution:
# If genuinely false positive → update alert rules
# If alert resolved → Alertmanager should auto-resolve (check resolve timeout)
```

---

## Q10. Kubernetes cluster upgrade broke several apps. Systematic approach?

```bash
# Before any upgrade: check compatibility
kubectl get apiservices | grep -v "True"  # Deprecated APIs in use?
kubectl get pods -A -o json | grep -o '"apiVersion":"[^"]*"' | sort | uniq
# Check against: https://kubernetes.io/docs/reference/using-api/deprecation-guide/

# During upgrade issues:
# 1. Check admission webhooks blocking new features
kubectl get validatingwebhookconfigurations
kubectl get mutatingwebhookconfigurations
# Webhook timeouts? Update webhook or disable temporarily

# 2. Check pod security admission (PSA new in 1.25)
kubectl get events -A | grep "violates PodSecurity"
# Some pods were using privileged mode that's now blocked
# Fix: update pod specs or adjust namespace PSA labels

# 3. Check API deprecation
kubectl get --raw /api/v1 | python3 -m json.tool | grep kind
# v1beta1 → v1 migration for Ingress, etc.

# 4. CRD version mismatch
kubectl get crds | grep -v "True"

# Rollback K8s upgrade:
# Managed K8s: depends on provider
# EKS: can roll back node groups, not control plane
# GKE: use maintenance windows + multi-cluster blue/green
# AKS: not possible on control plane → blue/green cluster upgrade

# Prevention:
# - Test in non-production first
# - Check changelogs for breaking changes
# - Run pluto: scan for deprecated API usage
# - Stage upgrade: upgrade 1 node pool at a time
```

---

## Q11. How do you debug a memory leak in a Node.js app running in Kubernetes?

```bash
# Step 1: Confirm it's a leak (memory grows over time, not just startup)
kubectl top pod my-node-app -n production
# Run every 5 min: memory should be stable after warmup

# Step 2: Get heap snapshot
# Add endpoint to app:
# const v8 = require('v8')
# app.get('/heap', (req, res) => {
#   const snapshot = v8.writeHeapSnapshot()
#   res.send({snapshot})
# })

kubectl port-forward pod/my-pod 3000:3000 -n production &
curl http://localhost:3000/heap

# Step 3: Copy snapshot from pod
kubectl cp production/my-pod:/app/heap.heapsnapshot ./heap.heapsnapshot

# Step 4: Analyze in Chrome DevTools
# Chrome → F12 → Memory → Load heap snapshot
# Look for: growing arrays, unclosed callbacks, global variable accumulation

# Step 5: Common Node.js leaks:
# - Event emitter not removed: emitter.removeListener()
# - Closure capturing large variables: minimize closure scope
# - Array.push() without bound: LRU cache or queue limit
# - setInterval without clearInterval: always store and clear
# - Redis/DB connections not released: connection.end()

# Step 6: Production-safe profiling
# Use: node --inspect=0.0.0.0:9229 app.js
kubectl port-forward pod/my-pod 9229:9229 -n staging
# Connect Chrome DevTools → chrome://inspect
```

---

## Q12. An Ansible playbook fails on 3 of 10 servers. How do you debug?

```bash
# Step 1: Check which tasks failed
ansible-playbook site.yml -i inventory.ini --diff 2>&1 | grep -A5 "FAILED"

# Step 2: Run only on failing hosts
ansible-playbook site.yml -i inventory.ini --limit "failed-host-1,failed-host-2"

# Step 3: Increase verbosity
ansible-playbook site.yml -i inventory.ini --limit failed-host-1 -vvv
# -v: task output
# -vvv: connection details, full JSON

# Step 4: Check what's different about the failing hosts
ansible failed-host-1 -i inventory.ini -m setup | grep ansible_os_family
ansible all -i inventory.ini -m command -a "uname -r"  # Kernel version?

# Step 5: Test ad-hoc
ansible failed-host-1 -m command -a "which docker" -i inventory.ini
ansible failed-host-1 -m shell -a "docker --version 2>&1" -i inventory.ini

# Common causes:
# - Different OS version (Ubuntu 20 vs 22)
# - Package not available in that region/repo
# - SSH key not deployed to those hosts
# - Different directory structure
# - Service names differ (httpd vs apache2)

# Step 6: Use conditionals after debugging
- name: Install apache (distro-specific)
  apt:
    name: apache2
  when: ansible_distribution == "Ubuntu"

- name: Install apache (RedHat)
  yum:
    name: httpd
  when: ansible_os_family == "RedHat"
```

---

## Q13. Helm upgrade failed. The chart is in a weird state. How do you recover?

```bash
# Check current state
helm status my-release -n production
# STATUS: pending-upgrade or failed

# Option 1: Try upgrade again
helm upgrade my-release ./chart -f values.yaml -n production
# Sometimes transient failure, second run works

# Option 2: Rollback to last good revision
helm history my-release -n production
helm rollback my-release 2 -n production  # Roll back to revision 2

# Option 3: Force upgrade (re-creates resources)
helm upgrade my-release ./chart -f values.yaml -n production --force

# Option 4: Manual cleanup of stuck release
# Find the failed release secret
kubectl get secrets -n production | grep "helm.sh/release"
# Delete the failed revision's secret
kubectl delete secret sh.helm.release.v1.my-release.v5 -n production
# Then re-run upgrade

# Option 5: Nuclear option (if nothing else works)
helm uninstall my-release -n production
# Check for any PVCs/PVs to preserve before uninstall
kubectl get pvc -n production
helm install my-release ./chart -f values.yaml -n production

# Prevention:
# Always use --atomic flag in CI/CD
helm upgrade --install my-release ./chart --atomic --wait
# --atomic: auto-rollbacks on failure
```

---

## Q14. Grafana shows gaps in metrics. Some metrics missing. How do you debug?

```bash
# Check if target is being scraped
# Prometheus UI → Status → Targets
# Look for: "down" status, "connection refused", "no route to host"

# Check ServiceMonitor / scrape config
kubectl get servicemonitor -n monitoring
kubectl describe servicemonitor my-app-monitor -n monitoring
# Is the selector matching the correct pods?

# Verify metrics endpoint is accessible
kubectl port-forward pod/my-app-pod 9090:9090 -n production &
curl http://localhost:9090/metrics | head -20

# Check Prometheus logs for scrape errors
kubectl logs -n monitoring prometheus-0 | grep "error\|fail\|REFUSED" | tail -20

# Common causes:
# 1. Pod not annotated for scraping
kubectl get pod my-pod -o yaml | grep prometheus.io

# 2. Firewall/NetworkPolicy blocking scrape
kubectl get networkpolicy -n production | grep -A5 "ingress"

# 3. Wrong port in ServiceMonitor
kubectl get svc my-svc -o yaml | grep "metrics\|9090"
# Does ServiceMonitor port name match?

# 4. Metrics endpoint removed after refactor
kubectl exec my-pod -- curl localhost:8080/metrics 2>&1 | head -5

# 5. High cardinality causing Prometheus to drop series
kubectl logs -n monitoring prometheus-0 | grep "cardinality"
```

---

## Q15. Sudden CPU spike on all pods simultaneously. What could cause this?

```bash
# Step 1: When did it start?
kubectl get events -n production --sort-by=.lastTimestamp | tail -20

# Step 2: Was there a deployment?
kubectl rollout history deployment -A | head -20

# Step 3: Traffic spike?
# Check HTTP request rate in Prometheus
# rate(http_requests_total[5m]) - sudden jump?

# Step 4: Background job started?
kubectl get cronjobs -A
kubectl get jobs -A | grep -v Complete

# Step 5: Dependency issue (waiting for slow DB)?
# High CPU + high memory → CPU spinning waiting on I/O

# Step 6: Infinite loop introduced?
kubectl logs -l app=my-app --tail=100 -n production | \
  grep -c "Processing"   # Thousands of lines per second = loop

# Common causes of simultaneous CPU spike:
# A: Scheduled job (CronJob) ran at top of hour
# B: Cache expired simultaneously (thundering herd)
# C: New code has hot loop
# D: External traffic surge
# E: Dependency became very slow → threads pile up

# Immediate mitigation:
kubectl scale deployment my-app --replicas=20 -n production  # Handle traffic
# OR for code regression:
kubectl rollout undo deployment my-app -n production

# Cache stampede prevention:
# Add jitter to cache expiry: expire = base_ttl + random(0, 30)
```
