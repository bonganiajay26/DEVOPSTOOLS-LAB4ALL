# DevOps + MLOps + AIOps Mastery Repository

> **Production-grade, hands-on learning labs for every major DevOps tool and concept.**
> Beginner → Advanced. Job-ready skills. Real-world scenarios.

---

## Repository Structure

```
devops-labs/
├── git/                    # Git fundamentals → advanced workflows
├── github-actions/         # CI/CD pipelines, reusable workflows
├── docker/                 # Containerization, multi-stage builds, security
├── kubernetes/             # Orchestration, RBAC, networking, HPA
├── helm/                   # Package management, chart development
├── kustomize/              # Declarative config management
├── terraform/              # Infrastructure as Code, modules, state
├── ansible/                # Configuration management, playbooks
├── prometheus-grafana/     # Observability stack, alerting, dashboards
├── sre/                    # SLOs, SLAs, error budgets, runbooks
├── platform-engineering/   # IDP, golden paths, Backstage
├── gitops/                 # ArgoCD, Flux, sync strategies
├── azure-devops/           # Azure Pipelines, Boards, Artifacts
├── aws-devops/             # CodePipeline, EKS, ECR, CloudFormation
├── gcp-devops/             # Cloud Build, GKE, Artifact Registry
├── mlops/                  # ML pipelines, model serving, drift detection
├── aiops/                  # Anomaly detection, intelligent alerting, LLMOps
└── troubleshooting/        # War stories, root cause analysis, playbooks
```

---

## How to Use This Repository

Each topic folder is **self-contained**:

| Folder | Contents |
|--------|----------|
| `/docs` | Concept explanations, architecture diagrams, use cases |
| `/examples` | 10+ working code examples (YAML, scripts, configs) |
| `/labs` | Step-by-step guided labs with real-world scenarios |
| `/interview-prep` | 15+ practical interview Q&A with scenario-based answers |
| `README.md` | Quick start, prerequisites, navigation |

---

## Learning Path

### Foundational (Start Here)
1. `git` → `docker` → `kubernetes`

### CI/CD & Automation
2. `github-actions` → `helm` → `kustomize` → `gitops`

### Infrastructure
3. `terraform` → `ansible` → `azure-devops` OR `aws-devops` OR `gcp-devops`

### Observability & Reliability
4. `prometheus-grafana` → `sre` → `platform-engineering`

### Advanced
5. `mlops` → `aiops` → `troubleshooting`

---

## Prerequisites

- Linux/macOS terminal or WSL2 on Windows
- Docker Desktop installed
- `kubectl` CLI installed
- A cloud account (AWS Free Tier / Azure Free / GCP Free Tier)
- Basic programming knowledge (Python or Bash)

---

## Integration Map

```
GitHub Actions ──► Docker Build ──► Push to Registry
                                         │
Terraform ────────► Kubernetes Cluster ◄─┘
                         │
Helm/Kustomize ─────────► Deploy Apps
                         │
Prometheus + Grafana ────► Observe & Alert
                         │
ArgoCD (GitOps) ─────────► Sync & Reconcile
                         │
MLOps Pipeline ──────────► Serve Models
                         │
AIOps Engine ────────────► Intelligent Ops
```

---

## Contributing

Each lab follows a standard template. See `CONTRIBUTING.md` for the lab authoring guide.

---

*Built for engineers who want job-ready skills fast. No fluff. Just working code.*
