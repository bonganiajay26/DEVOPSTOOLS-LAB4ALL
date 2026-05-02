# Kubernetes

> **Orchestrate containers at scale. From zero to production in 5 labs.**

---

## What You'll Learn

- Core Kubernetes objects: Pod, Deployment, Service, ConfigMap, Secret
- Networking: ClusterIP, NodePort, LoadBalancer, Ingress
- Storage: PV, PVC, StorageClass
- Security: RBAC, NetworkPolicies, Pod Security Standards
- Autoscaling: HPA, VPA, KEDA
- Production patterns: rolling updates, canary, blue/green
- Debugging and troubleshooting live clusters

---

## Quick Navigation

| Section | Description |
|---------|-------------|
| [docs/01-concepts.md](docs/01-concepts.md) | Core concepts and object model |
| [docs/02-architecture.md](docs/02-architecture.md) | Control plane, data plane, networking internals |
| [docs/03-use-cases.md](docs/03-use-cases.md) | Real-world deployment patterns |
| [examples/](examples/) | 12 production-ready YAML examples |
| [labs/](labs/) | 5 guided hands-on labs |
| [interview-prep/questions.md](interview-prep/questions.md) | 20 interview Q&A with scenario answers |

---

## Prerequisites

```bash
# Install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# Install kind (local cluster)
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.22.0/kind-linux-amd64
chmod +x kind && sudo mv kind /usr/local/bin/

# Or install minikube
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube

# Verify
kubectl version --client
```

---

## 5-Minute Quick Start

```bash
# 1. Create local cluster
kind create cluster --name devops-lab

# 2. Deploy a sample app
kubectl create deployment nginx --image=nginx:1.25
kubectl expose deployment nginx --port=80 --type=NodePort

# 3. Check status
kubectl get pods,svc

# 4. Access the app
kubectl port-forward svc/nginx 8080:80
# Open http://localhost:8080

# 5. Clean up
kind delete cluster --name devops-lab
```

---

## Labs Overview

| Lab | Scenario | Difficulty |
|-----|----------|------------|
| Lab 01 | Local cluster setup + first deployment | Beginner |
| Lab 02 | Deploy a 3-tier microservices app | Intermediate |
| Lab 03 | CI/CD pipeline with GitHub Actions | Intermediate |
| Lab 04 | Full observability with Prometheus/Grafana | Advanced |
| Lab 05 | RBAC, Network Policies, Pod Security | Advanced |
