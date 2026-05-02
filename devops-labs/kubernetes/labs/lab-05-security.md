# Lab 05: Kubernetes Security — RBAC, Network Policies & Pod Security

**Difficulty**: Advanced | **Time**: 60 minutes  
**Goal**: Harden a production cluster — least-privilege RBAC, network segmentation, pod security standards.

---

## Security Layers We Cover

```
1. Authentication   — Who are you? (kubeconfig, OIDC, ServiceAccounts)
2. Authorization    — What can you do? (RBAC)
3. Admission        — Is your manifest allowed? (Pod Security Admission, OPA)
4. Network          — Who can talk to whom? (NetworkPolicies)
5. Runtime          — What can the container do? (securityContext, seccomp)
```

---

## Part 1: RBAC — Principle of Least Privilege

### Audit current permissions

```bash
# What can the default service account do? (too much)
kubectl auth can-i --list --as=system:serviceaccount:production:default -n production

# What can a developer do?
kubectl auth can-i create deployments --as=john@company.com -n production
kubectl auth can-i delete pods --as=john@company.com -n production
```

### Create scoped service accounts

```bash
# Create namespace
kubectl create namespace production

# Create service account — no auto-mounted token
cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: api-service-sa
  namespace: production
automountServiceAccountToken: false
EOF

# Create minimal role
cat << 'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: api-service-role
  namespace: production
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "watch"]
  resourceNames: ["api-config"]     # Only THIS specific configmap
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get"]
  resourceNames: ["api-secrets"]   # Only THIS specific secret
EOF

# Bind SA to role
cat << 'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: api-service-binding
  namespace: production
subjects:
- kind: ServiceAccount
  name: api-service-sa
  namespace: production
roleRef:
  kind: Role
  apiGroup: rbac.authorization.k8s.io
  name: api-service-role
EOF

# Verify permissions
kubectl auth can-i get secrets --as=system:serviceaccount:production:api-service-sa -n production
# yes
kubectl auth can-i list secrets --as=system:serviceaccount:production:api-service-sa -n production
# no (only get, not list)
kubectl auth can-i delete pods --as=system:serviceaccount:production:api-service-sa -n production
# no
```

### Create developer read-only access

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: dev-readonly
  namespace: production
rules:
- apiGroups: ["", "apps", "batch", "autoscaling"]
  resources: ["pods", "pods/log", "pods/exec", "deployments",
              "replicasets", "services", "configmaps", "events",
              "jobs", "cronjobs", "horizontalpodautoscalers"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: dev-readonly-binding
  namespace: production
subjects:
- kind: Group
  name: "developers"               # Matches OIDC group claim
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  apiGroup: rbac.authorization.k8s.io
  name: dev-readonly
EOF
```

---

## Part 2: Pod Security Standards

### Enable Pod Security Admission on namespace

```bash
# Label namespace with policy
kubectl label namespace production \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted

# Test: try to deploy a privileged pod (should be BLOCKED)
cat << 'EOF' | kubectl apply -f - 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: privileged-pod
  namespace: production
spec:
  containers:
  - name: app
    image: nginx
    securityContext:
      privileged: true
EOF
# Expected: Error from server (Forbidden): pods "privileged-pod" is forbidden:
#           violates PodSecurity "restricted:latest"

# Deploy a compliant pod
cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: secure-pod
  namespace: production
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault           # Restrict syscalls
  containers:
  - name: app
    image: nginx:1.25-alpine
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]                # Drop ALL Linux capabilities
    volumeMounts:
    - name: tmp
      mountPath: /tmp
    - name: nginx-cache
      mountPath: /var/cache/nginx
    - name: nginx-run
      mountPath: /var/run
  volumes:
  - name: tmp
    emptyDir: {}
  - name: nginx-cache
    emptyDir: {}
  - name: nginx-run
    emptyDir: {}
EOF

kubectl get pod secure-pod -n production
```

---

## Part 3: Network Policies — Zero-Trust Networking

```bash
# Install Calico (supports NetworkPolicies)
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml

# Create test namespaces
kubectl create namespace frontend
kubectl create namespace backend
kubectl create namespace database

# Label namespaces for NetworkPolicy selectors
kubectl label namespace frontend kubernetes.io/metadata.name=frontend
kubectl label namespace backend kubernetes.io/metadata.name=backend
kubectl label namespace database kubernetes.io/metadata.name=database

# Deploy test pods
kubectl run frontend-pod --image=curlimages/curl:latest -n frontend \
  --labels="app=frontend" -- sleep 3600
kubectl run backend-pod --image=nginx:alpine -n backend \
  --labels="app=backend"
kubectl run db-pod --image=postgres:15-alpine -n database \
  --labels="app=postgres" \
  --env="POSTGRES_PASSWORD=test"

# Wait for pods
kubectl wait --for=condition=Ready pod --all -n frontend --timeout=60s
kubectl wait --for=condition=Ready pod --all -n backend --timeout=60s

# Test connectivity BEFORE policies (should succeed)
BACKEND_IP=$(kubectl get pod backend-pod -n backend -o jsonpath='{.status.podIP}')
kubectl exec -n frontend frontend-pod -- curl -s --max-time 3 http://$BACKEND_IP || echo "FAIL"
```

### Apply deny-all then open up selectively

```bash
# Step 1: Default deny all in backend namespace
cat << 'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: backend
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
EOF

# Test (should fail now)
kubectl exec -n frontend frontend-pod -- curl -s --max-time 3 http://$BACKEND_IP
# Expected: curl: (28) Connection timed out

# Step 2: Allow frontend → backend
cat << 'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-ingress
  namespace: backend
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: frontend
      podSelector:
        matchLabels:
          app: frontend
    ports:
    - protocol: TCP
      port: 80
EOF

# Test (should succeed now)
kubectl exec -n frontend frontend-pod -- curl -s --max-time 3 http://$BACKEND_IP
# Expected: nginx welcome page HTML

# Step 3: Allow DNS egress from backend
cat << 'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: backend
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
EOF

# Verify DNS works from backend
kubectl exec -n backend backend-pod -- nslookup kubernetes.default
```

---

## Part 4: Audit Logging

```bash
# Create audit policy
cat > /tmp/audit-policy.yaml << 'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
# Log all secret access at RequestResponse level
- level: RequestResponse
  resources:
  - group: ""
    resources: ["secrets"]

# Log pod exec and port-forward
- level: Request
  verbs: ["create"]
  resources:
  - group: ""
    resources: ["pods/exec", "pods/portforward", "pods/attach"]

# Log auth failures
- level: Metadata
  omitStages:
  - RequestReceived

# Don't log read-only health checks
- level: None
  users: ["system:serviceaccount:kube-system:generic-garbage-collector"]
  verbs: ["get", "list", "watch"]
EOF

echo "Audit policy created at /tmp/audit-policy.yaml"
echo "Apply to kube-apiserver: --audit-policy-file=/etc/kubernetes/audit-policy.yaml"
echo "                         --audit-log-path=/var/log/kubernetes/audit.log"
```

---

## Part 5: Secret Scanning with Falco

```bash
# Install Falco (runtime security)
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm install falco falcosecurity/falco \
  --namespace falco \
  --create-namespace \
  --set falco.grpc.enabled=true \
  --set falco.grpcOutput.enabled=true

# Custom Falco rule — alert if someone reads a secret from a pod
cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: falco-custom-rules
  namespace: falco
data:
  custom-rules.yaml: |
    - rule: Read Sensitive File in Container
      desc: Detect attempts to read sensitive files
      condition: >
        open_read and container and
        (fd.name contains "/etc/shadow" or
         fd.name contains "/.aws/credentials" or
         fd.name contains "/.ssh/id_rsa")
      output: >
        Sensitive file read in container
        (file=%fd.name container=%container.name image=%container.image.repository)
      priority: WARNING
      tags: [filesystem, security]
EOF

kubectl rollout restart daemonset/falco -n falco
kubectl logs -l app.kubernetes.io/name=falco -n falco --tail=20
```

---

## Security Checklist

```bash
# Run CIS Benchmark
kubectl apply -f https://raw.githubusercontent.com/aquasecurity/kube-bench/main/job.yaml
kubectl logs job/kube-bench

# Check for exposed secrets in env vars
kubectl get pods -A -o json | \
  jq '.items[].spec.containers[].env[]? | select(.value != null) | 
      select(.name | test("PASSWORD|SECRET|KEY|TOKEN"; "i"))'

# Find pods running as root
kubectl get pods -A -o json | \
  jq '.items[] | select(.spec.containers[].securityContext.runAsUser == 0 or
      .spec.securityContext.runAsUser == 0) | .metadata.name'

# Find pods with hostNetwork
kubectl get pods -A -o json | \
  jq '.items[] | select(.spec.hostNetwork == true) | .metadata.name'
```

---

## What You Learned

- [x] RBAC with least-privilege service accounts
- [x] Pod Security Standards (restricted policy)
- [x] Network Policies for zero-trust networking
- [x] Audit logging configuration
- [x] Runtime security with Falco
- [x] Security scanning and compliance checking
