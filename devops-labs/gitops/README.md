# GitOps

> **Git as the single source of truth for infrastructure and application state. ArgoCD & Flux.**

---

## Quick Navigation

| Section | Contents |
|---------|----------|
| [docs/01-concepts.md](docs/01-concepts.md) | GitOps principles, ArgoCD, Flux |
| [examples/](examples/) | ArgoCD Apps, Flux Kustomizations |
| [labs/](labs/) | Full GitOps pipeline lab |
| [interview-prep/questions.md](interview-prep/questions.md) | 15 interview Q&A |

---

## GitOps Principles

```
1. Declarative: entire system described declaratively (YAML in Git)
2. Versioned: Git is the single source of truth (audit trail, rollback)
3. Automatic: approved changes are applied automatically
4. Continuous reconciliation: agents detect and correct drift
```

---

## Quick Start — ArgoCD

```bash
# Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d

# Access UI
kubectl port-forward svc/argocd-server -n argocd 8080:443

# CLI login
argocd login localhost:8080 --username admin --password <above>

# Create app
argocd app create my-api \
  --repo https://github.com/myorg/gitops \
  --path apps/my-api/overlays/production \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace production \
  --sync-policy automated \
  --auto-prune \
  --self-heal
```
