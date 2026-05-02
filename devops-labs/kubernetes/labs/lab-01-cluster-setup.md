# Lab 01: Kubernetes Cluster Setup & First Deployment

**Difficulty**: Beginner | **Time**: 30 minutes  
**Goal**: Spin up a local cluster, deploy a real app, understand the full lifecycle.

---

## Prerequisites
- Docker Desktop running
- 4 GB RAM available
- `kubectl` and `kind` installed (see main README)

---

## Part 1: Create a Local Cluster with kind

### Step 1: Create a multi-node cluster config

```bash
cat > kind-cluster.yaml << 'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: devops-lab
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
- role: worker
  labels:
    tier: compute
- role: worker
  labels:
    tier: compute
EOF
```

### Step 2: Create the cluster

```bash
kind create cluster --config kind-cluster.yaml

# Verify nodes are ready
kubectl get nodes
# Expected:
# NAME                       STATUS   ROLES           AGE
# devops-lab-control-plane   Ready    control-plane   2m
# devops-lab-worker          Ready    <none>          90s
# devops-lab-worker2         Ready    <none>          90s
```

### Step 3: Explore the cluster

```bash
# Cluster info
kubectl cluster-info

# All system components
kubectl get all -n kube-system

# Node details
kubectl describe node devops-lab-control-plane

# API resources available
kubectl api-resources | head -30
```

---

## Part 2: Deploy Your First Application

### Step 1: Create a namespace

```bash
kubectl create namespace myapp
# Verify
kubectl get namespaces
```

### Step 2: Deploy a web application

```bash
# Create deployment
kubectl create deployment webapp \
  --image=nginx:1.25-alpine \
  --replicas=3 \
  --namespace=myapp

# Watch it come up
kubectl get pods -n myapp -w
# Wait until all 3 show Running

# Describe one pod
kubectl describe pod -l app=webapp -n myapp | head -50
```

### Step 3: Expose with a Service

```bash
# Create ClusterIP service
kubectl expose deployment webapp \
  --port=80 \
  --target-port=80 \
  --namespace=myapp

# Verify endpoints (these are the actual pod IPs)
kubectl get endpoints webapp -n myapp

# Test connectivity from inside the cluster
kubectl run test-curl --image=curlimages/curl:latest -it --rm \
  --namespace=myapp \
  -- curl http://webapp.myapp.svc.cluster.local

# Access from your machine via port-forward
kubectl port-forward svc/webapp 8080:80 -n myapp &
curl http://localhost:8080
# You should see the nginx welcome page
```

### Step 4: Scale and observe

```bash
# Scale up
kubectl scale deployment webapp --replicas=5 -n myapp
kubectl get pods -n myapp

# Simulate traffic and watch load distribution
for i in $(seq 1 10); do
  kubectl run curl-$i --image=curlimages/curl:latest \
    --namespace=myapp \
    --rm -it --restart=Never \
    -- curl -s http://webapp.myapp.svc.cluster.local | grep -o "Served by.*"
done
```

---

## Part 3: Rolling Update & Rollback

### Step 1: Trigger a rolling update

```bash
# Update image version (triggers rolling update)
kubectl set image deployment/webapp nginx=nginx:1.24-alpine -n myapp

# Watch the rollout in real time
kubectl rollout status deployment/webapp -n myapp

# See what happened
kubectl describe deployment webapp -n myapp | grep -A5 "Events"
```

### Step 2: Verify zero downtime (run in a separate terminal)

```bash
# In terminal 1: constant requests
while true; do
  curl -s http://localhost:8080 > /dev/null && echo "OK $(date)" || echo "FAIL $(date)"
  sleep 0.5
done

# In terminal 2: trigger the rollout
kubectl set image deployment/webapp nginx=nginx:1.25-alpine -n myapp
```

### Step 3: Rollback

```bash
# View rollout history
kubectl rollout history deployment/webapp -n myapp

# Rollback to previous version
kubectl rollout undo deployment/webapp -n myapp

# Verify rollback
kubectl rollout status deployment/webapp -n myapp
kubectl describe deployment webapp -n myapp | grep Image
```

---

## Part 4: Debug a Failing Pod

### Step 1: Create a broken deployment

```bash
kubectl create deployment broken \
  --image=nginx:doesnotexist999 \
  --namespace=myapp

# Watch it fail
kubectl get pods -n myapp -w
```

### Step 2: Debug techniques

```bash
# Get pod status
kubectl get pods -n myapp | grep broken

# Describe: shows Events section with error messages
kubectl describe pod -l app=broken -n myapp

# Check events (best first stop for debugging)
kubectl get events -n myapp --sort-by=.lastTimestamp | tail -20

# Fix it
kubectl set image deployment/broken nginx=nginx:1.25-alpine -n myapp
kubectl rollout status deployment/broken -n myapp
```

---

## Part 5: Cleanup

```bash
# Delete namespace (removes everything inside)
kubectl delete namespace myapp

# Delete the cluster
kind delete cluster --name devops-lab

echo "Lab 01 complete!"
```

---

## What You Learned

- [x] Creating a multi-node kind cluster
- [x] Creating Deployments, Services, Namespaces
- [x] Rolling updates and rollbacks
- [x] Port-forwarding for local access
- [x] Debugging pods with describe/events/logs

## Next Lab

→ [Lab 02: Deploy a 3-Tier Microservices Application](lab-02-microservices.md)
