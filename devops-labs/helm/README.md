# Helm

> **The package manager for Kubernetes. Templatize, version, and deploy complex applications.**

---

## Quick Navigation

| Section | Contents |
|---------|----------|
| [docs/01-concepts.md](docs/01-concepts.md) | Charts, releases, repositories, templating |
| [examples/](examples/) | Chart templates, values, hooks |
| [labs/](labs/) | Build and publish a production Helm chart |
| [interview-prep/questions.md](interview-prep/questions.md) | 15 interview Q&A |

---

## Quick Start

```bash
# Install Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Add popular repos
helm repo add stable         https://charts.helm.sh/stable
helm repo add bitnami        https://charts.bitnami.com/bitnami
helm repo add prometheus-com https://prometheus-community.github.io/helm-charts
helm repo update

# Search and install
helm search repo nginx
helm install my-nginx bitnami/nginx --namespace web --create-namespace

# Inspect a chart before install
helm show values bitnami/postgresql

# Install with custom values
helm install my-pg bitnami/postgresql \
  --set auth.password=mypassword \
  --set primary.persistence.size=20Gi

# Or with values file
helm install my-pg bitnami/postgresql -f postgres-values.yaml

# Upgrade
helm upgrade my-pg bitnami/postgresql -f postgres-values.yaml

# Rollback
helm rollback my-pg 1          # Rollback to release revision 1
helm history my-pg             # See all revisions

# Uninstall
helm uninstall my-pg
```
