# Kubernetes Architecture

## High-Level Overview

```
┌─────────────────────────────────────────────────────────┐
│                    CONTROL PLANE                         │
│                                                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │  API Server  │  │  Controller  │  │  Scheduler   │  │
│  │ (kube-apiserver)│  │  Manager    │  │              │  │
│  └──────┬───────┘  └──────────────┘  └──────────────┘  │
│         │                                                │
│  ┌──────▼───────┐  ┌──────────────┐                     │
│  │     etcd     │  │ cloud-controller│                  │
│  │ (state store)│  │   manager    │                     │
│  └──────────────┘  └──────────────┘                     │
└─────────────────────────────────────────────────────────┘
                          │ watches/updates
┌─────────────────────────▼───────────────────────────────┐
│                     WORKER NODES                         │
│                                                          │
│  ┌─────────────────────────────────────────────────┐    │
│  │                   Node 1                         │    │
│  │  ┌──────────┐  ┌──────────┐  ┌───────────────┐ │    │
│  │  │  kubelet │  │kube-proxy│  │container-runtime│ │    │
│  │  └──────────┘  └──────────┘  └───────────────┘ │    │
│  │  ┌────────┐  ┌────────┐  ┌────────┐            │    │
│  │  │ Pod 1  │  │ Pod 2  │  │ Pod 3  │            │    │
│  │  └────────┘  └────────┘  └────────┘            │    │
│  └─────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────┐    │
│  │                   Node 2                         │    │
│  │  ... same components ...                         │    │
│  └─────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────┘
```

---

## Control Plane Components

### kube-apiserver
The **front door** to Kubernetes. Every operation goes through it.
- Validates and processes API requests
- Reads/writes to etcd
- Handles authentication, authorization (RBAC), admission control
- RESTful API — everything is a resource (GET/POST/PUT/DELETE/WATCH)

**What happens when you run `kubectl apply -f deployment.yaml`:**
1. kubectl serializes manifest → sends HTTPS POST to apiserver
2. apiserver authenticates (your kubeconfig cert)
3. apiserver authorizes (RBAC check)
4. Admission webhooks run (OPA, Kyverno, etc.)
5. Object validated against schema
6. Written to etcd
7. Controller Manager picks up the change
8. Scheduler places pods on nodes
9. kubelet creates containers

### etcd
Distributed key-value store — the **single source of truth**.
- Stores all cluster state: pods, deployments, configmaps, secrets, everything
- Uses Raft consensus protocol
- In production: always run as a 3 or 5 node cluster (odd numbers for quorum)
- Backup etcd daily. Losing it = losing the entire cluster state.

```bash
# Backup etcd (run on control plane node)
ETCDCTL_API=3 etcdctl snapshot save /backup/etcd-snapshot.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
```

### kube-scheduler
Decides **which node** a new pod runs on.

Scheduling process:
1. **Filter** (Predicates): Remove nodes that can't run the pod
   - Insufficient CPU/memory
   - Node has taint the pod doesn't tolerate
   - Node doesn't match nodeSelector/nodeAffinity
2. **Score** (Priorities): Rank remaining nodes
   - Least requested resources
   - Pod affinity/anti-affinity rules
   - Data locality
3. **Bind**: Assign pod to highest-scored node

### kube-controller-manager
Runs all built-in controllers in a single process. Each controller watches a specific resource type and reconciles desired vs actual state.

| Controller | Responsibility |
|-----------|----------------|
| Deployment Controller | Creates/manages ReplicaSets |
| ReplicaSet Controller | Ensures correct pod count |
| Node Controller | Handles node failures, marks NotReady |
| Service Account Controller | Creates default SAs in new namespaces |
| Endpoint Controller | Populates Endpoints objects for Services |
| Job Controller | Manages Job completion |
| Namespace Controller | Handles namespace deletion |

---

## Worker Node Components

### kubelet
The **agent** on every node. Talks to the container runtime.
- Receives PodSpecs from apiserver
- Creates containers via CRI (Container Runtime Interface)
- Reports node and pod status back to apiserver
- Runs liveness/readiness probes
- Manages volumes and secrets

### kube-proxy
Implements Service networking on each node.
- Maintains iptables/ipvs rules
- Routes traffic from Service IP to actual Pod IPs
- Three modes: iptables (default), ipvs (high perf), userspace (legacy)

### Container Runtime
Implements CRI. Options:
- **containerd** (production standard, used by most managed K8s)
- **CRI-O** (lightweight, used by OpenShift)
- ~~Docker~~ (removed in K8s 1.24 — dockershim deprecated)

---

## Networking Deep Dive

### Pod-to-Pod Communication
Every pod gets a unique IP from the Pod CIDR range. Communication is direct, no NAT. Implemented by the CNI plugin.

**CNI Plugin Options:**

| Plugin | Use Case |
|--------|----------|
| Calico | Network policies, high performance, BGP routing |
| Cilium | eBPF-based, L7 policies, service mesh built-in |
| Flannel | Simple overlay, great for dev/learning |
| Weave | Simple, encrypted by default |
| AWS VPC CNI | Native AWS networking (EKS default) |

### Service Networking
```
Client Pod ──► Service VirtualIP:Port
                      │
              kube-proxy iptables rules
                      │
              ─────────────────────
              │         │         │
           Pod A      Pod B      Pod C
```

### DNS Resolution
CoreDNS runs as a Deployment in `kube-system`. Every pod's `/etc/resolv.conf` points to CoreDNS.

```bash
# Full DNS name for a service
<service>.<namespace>.svc.<cluster-domain>
# Example:
postgres.database.svc.cluster.local

# Short names work within same namespace
postgres
postgres.database
```

### Ingress Architecture
```
Internet ──► LoadBalancer ──► Ingress Controller Pod
                                      │
                         ─────────────────────────
                         │                       │
                  /api → backend-svc       /web → frontend-svc
```

Popular Ingress Controllers:
- **nginx-ingress**: Most common, full-featured
- **Traefik**: Auto-discovery, Let's Encrypt built-in
- **AWS ALB Controller**: Native AWS integration
- **Kong**: API gateway capabilities

---

## Storage Architecture

```
Pod ──► PersistentVolumeClaim ──► PersistentVolume ──► Storage Backend
                                    (Static or                (EBS, NFS,
                               Dynamic via StorageClass)      Ceph, etc.)
```

### Dynamic Provisioning Flow
1. Pod requests storage via PVC
2. StorageClass provisioner creates PV automatically
3. PV bound to PVC
4. Pod mounts PVC as volume

```yaml
# StorageClass defines HOW storage is provisioned
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-ssd
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  iops: "3000"
  throughput: "125"
reclaimPolicy: Retain  # Retain | Delete | Recycle
volumeBindingMode: WaitForFirstConsumer
```

---

## Production Control Plane Setup

```
                    ┌─────────────────────────────────┐
                    │   Load Balancer (HAProxy/NLB)   │
                    └─────────────────────────────────┘
                      /            |            \
              ┌───────┐      ┌───────┐      ┌───────┐
              │  CP 1 │      │  CP 2 │      │  CP 3 │
              │       │      │       │      │       │
              │ API   │      │ API   │      │ API   │
              │ etcd  │      │ etcd  │      │ etcd  │
              │ CM    │      │ CM    │      │ CM    │
              │ Sched │      │ Sched │      │ Sched │
              └───────┘      └───────┘      └───────┘
                              etcd cluster (Raft)
```

**3 control plane nodes** = survives loss of 1 node (quorum = 2)
**5 control plane nodes** = survives loss of 2 nodes (quorum = 3)

---

## Key Ports Reference

| Component | Port | Protocol |
|-----------|------|----------|
| kube-apiserver | 6443 | HTTPS |
| etcd | 2379-2380 | HTTPS |
| kubelet | 10250 | HTTPS |
| kube-proxy | 10256 | HTTP |
| kube-scheduler | 10259 | HTTPS |
| controller-manager | 10257 | HTTPS |
| NodePort range | 30000-32767 | TCP/UDP |
