# Kubernetes Troubleshooting Playbook

## Pod States Reference

| Status | Meaning | First Action |
|--------|---------|-------------|
| `Pending` | Not scheduled yet | `kubectl describe pod` → check Events |
| `ContainerCreating` | Pulling image, creating | `kubectl describe pod` → check image name |
| `CrashLoopBackOff` | App crashes repeatedly | `kubectl logs --previous` |
| `ImagePullBackOff` | Can't pull image | Check image name, registry credentials |
| `OOMKilled` | Out of memory | Increase memory limit |
| `Terminating` stuck | Finalizer blocking deletion | Check finalizers, force delete |
| `Evicted` | Node pressure | Check node disk/memory |
| `Init:Error` | Init container failed | `kubectl logs pod -c init-container-name` |

---

## Scenario 1: Pod Stuck in Pending

```bash
# Step 1: Describe the pod
kubectl describe pod my-pod -n production
# Read the EVENTS section at the bottom carefully

# Scenario A: Insufficient resources
# "0/3 nodes are available: 3 Insufficient cpu"
kubectl describe nodes | grep -A5 "Allocated resources"
kubectl top nodes  # Need metrics-server

# Fix: Scale up node pool OR reduce resource requests
kubectl patch deployment my-app -p \
  '{"spec":{"template":{"spec":{"containers":[{"name":"app","resources":{"requests":{"cpu":"100m"}}}]}}}}'

# Scenario B: Node selector doesn't match
# "0/3 nodes are available: 3 node(s) didn't match Pod's node affinity"
kubectl get nodes --show-labels | grep "disk-type"

# Fix: Label a node
kubectl label node node-1 disk-type=ssd

# Scenario C: Taints not tolerated
# "0/3 nodes are available: 3 node(s) had taint {key:NoSchedule}"
kubectl get nodes -o json | jq '.items[].spec.taints'

# Fix: Add toleration to pod
# OR: Remove taint if it shouldn't be there
kubectl taint nodes node-1 key:NoSchedule-  # Remove taint

# Scenario D: PVC not bound
kubectl get pvc -n production
kubectl describe pvc my-pvc -n production
# "waiting for a volume to be created"
# Check StorageClass provisioner, cloud provider status
```

---

## Scenario 2: CrashLoopBackOff

```bash
# Step 1: Get current logs
kubectl logs my-pod -n production --tail=100

# Step 2: Get previous container logs (after restart)
kubectl logs my-pod -n production --previous --tail=100

# Step 3: Check exit code
kubectl describe pod my-pod -n production | grep -A5 "Last State"
# Exit Code 1 = Application error (check logs)
# Exit Code 137 = OOM killed (increase memory limit)
# Exit Code 139 = Segfault (app bug)
# Exit Code 143 = SIGTERM not handled (increase terminationGracePeriod)

# Step 4: Exec into a running instance (if startup phase is long enough)
kubectl exec -it my-pod -n production -- sh

# Step 5: Override command for debugging
kubectl run debug-pod \
  --image=my-crashing-image:latest \
  --command -- sleep 3600   # Override CMD, keep container alive
kubectl exec -it debug-pod -- sh
# Now investigate inside

# Common causes:
# - Missing environment variable: "env: DATABASE_URL not set"
# - Wrong command/args in Dockerfile
# - Port conflict (two containers on same port)
# - Config file missing (volume not mounted)
# - Permission denied (non-root can't read file owned by root)
```

---

## Scenario 3: Service Not Routing Traffic

```bash
# Symptom: curl service-name returns connection refused / no response

# Step 1: Check endpoints (are pods actually in service?)
kubectl get endpoints my-service -n production
# Empty = selector doesn't match any pods

# Step 2: Verify selector matches pod labels
kubectl get svc my-service -o yaml | grep -A5 selector
kubectl get pods -l app=my-app -n production  # Must return pods

# Step 3: Test pod directly (bypass service)
POD_IP=$(kubectl get pod my-pod -o jsonpath='{.status.podIP}')
kubectl run nettest --image=curlimages/curl --rm -it -- \
  curl http://$POD_IP:8080/health

# Step 4: Test service from inside cluster
kubectl run nettest --image=curlimages/curl --rm -it -- \
  curl http://my-service.production.svc.cluster.local/health

# Step 5: Check if pod is Ready
kubectl get pods -n production
# Ready 0/1 = pod exists but not ready → readiness probe failing

# Step 6: Check port mapping
kubectl get svc my-service -o yaml
# port: 80 → targetPort: 8080
# Must match containerPort in pod spec

# Step 7: Network policy blocking?
kubectl get networkpolicy -n production
# If policies exist, trace source → destination
```

---

## Scenario 4: Node NotReady

```bash
# Step 1: Check node conditions
kubectl describe node problem-node | grep -A30 "Conditions:"
# MemoryPressure, DiskPressure, PIDPressure, Ready=False

# Step 2: SSH to the node
# AWS: aws ssm start-session --target i-xxxxx
# GCP: gcloud compute ssh node-name
# Azure: az vm run-command invoke --command-id RunShellScript

# Step 3: Check kubelet
sudo systemctl status kubelet
sudo journalctl -u kubelet -n 50

# Step 4: Check disk
df -h  # Is /var/lib/docker or /var/lib/containerd full?
# Fix: Clean up
sudo docker system prune -f  # If Docker
sudo crictl rmi --prune     # If containerd
sudo journalctl --vacuum-size=2G

# Step 5: Check memory
free -h
# OOM? Check /var/log/syslog or dmesg
sudo dmesg | grep -i oom | tail -20

# Step 6: Check container runtime
sudo systemctl status containerd
sudo crictl info

# Step 7: Emergency workload rescue
# Cordon node (no new scheduling)
kubectl cordon problem-node

# Drain workloads to other nodes
kubectl drain problem-node --ignore-daemonsets --delete-emissary-data

# After fixing the node:
kubectl uncordon problem-node
```

---

## Scenario 5: Ingress Returns 502/503/504

```bash
# 502 Bad Gateway = Ingress reached backend, but backend returned error
# 503 Service Unavailable = No healthy backends
# 504 Gateway Timeout = Backend too slow

# Step 1: Check ingress controller logs
kubectl logs -n ingress-nginx \
  -l app.kubernetes.io/name=ingress-nginx \
  --tail=100 | grep -E "error|502|503|504"

# Step 2: Check if backend service has endpoints
kubectl get endpoints my-service -n production
# Empty = no healthy pods!

# Step 3: Check backend pods
kubectl get pods -n production -l app=my-app
# Are they Running and Ready (1/1)?

# Step 4: Check ingress configuration
kubectl describe ingress my-ingress -n production
# Look for: port mismatch, wrong service name, wrong path

# Step 5: Test backend directly
kubectl port-forward svc/my-service 8080:80 -n production &
curl http://localhost:8080/health
# Does it respond? What does it return?

# Step 6: Check for SSL/cert issues
kubectl describe certificate my-tls -n production
# Is the certificate Ready? Not expired?

# Step 7: Check resource limits (504 = often CPU throttling)
kubectl top pods -n production
kubectl describe pod my-app -n production | grep -A5 "Limits:"
```

---

## Scenario 6: kubectl apply Fails

```bash
# Error: "the server does not allow this method on the requested resource"
# → RBAC: your service account can't do that operation
kubectl auth can-i apply deployments -n production
kubectl auth can-i --list -n production  # What CAN you do?

# Error: "namespaces 'production' not found"
kubectl create namespace production

# Error: "unable to recognize 'file.yaml': no matches for kind 'X'"
# → CRD not installed
kubectl get crd | grep "my-resource"
# Install the CRD first

# Error: "metadata.annotations: Too long"
# → Apply annotation is too large (client-side apply metadata)
kubectl apply -f file.yaml --server-side  # Use server-side apply

# Error: "field is immutable"
# → Can't change this field without recreating (e.g., selector)
kubectl delete deployment my-deploy
kubectl apply -f file.yaml

# DryRun to preview:
kubectl apply -f file.yaml --dry-run=server
```

---

## Emergency Commands

```bash
# Force delete stuck terminating pod
kubectl delete pod stuck-pod -n production \
  --grace-period=0 --force

# Remove finalizer from stuck resource
kubectl patch pod stuck-pod -n production \
  -p '{"metadata":{"finalizers":[]}}' \
  --type=merge

# Roll back a deployment NOW
kubectl rollout undo deployment/my-app -n production

# Emergency scale down (stop broken app)
kubectl scale deployment/my-app --replicas=0 -n production

# Cordon all nodes (stop scheduling — emergency freeze)
kubectl get nodes -o name | xargs -I{} kubectl cordon {}

# Check what's using most resources
kubectl top pods -A --sort-by=memory | head -20
kubectl top nodes

# Find pods that have been restarting
kubectl get pods -A | awk '$4 > 5'  # More than 5 restarts

# Get events for whole namespace (sorted by time)
kubectl get events -n production \
  --sort-by='.lastTimestamp' \
  --field-selector type=Warning
```
