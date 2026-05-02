# Platform Engineering

> **Build an Internal Developer Platform (IDP) that enables developers to self-serve infrastructure.**

---

## Quick Navigation

| Section | Contents |
|---------|----------|
| [docs/01-concepts.md](docs/01-concepts.md) | IDP, golden paths, Backstage, Crossplane |
| [examples/](examples/) | Backstage catalog, Crossplane XRDs |
| [interview-prep/questions.md](interview-prep/questions.md) | 15 interview Q&A |

---

## What is Platform Engineering?

```
Traditional DevOps:
  Dev team → asks Ops team → Ops provisions infra → Dev deploys

Platform Engineering:
  Platform team → builds IDP → Dev self-serves everything

Internal Developer Platform (IDP):
  Developer Portal (Backstage) — service catalog, documentation
  Infrastructure Templates — new service in 5 minutes
  Self-service DB provisioning
  Paved roads (golden paths) for common patterns
  Automated compliance (security, cost controls built-in)
```

---

## Core Components

```
┌─────────────────────────────────────────────────────────────┐
│                Internal Developer Platform                   │
│                                                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │
│  │  Backstage  │  │  Crossplane │  │   Argo Workflows    │ │
│  │  (portal)   │  │  (infra     │  │   (day 2 ops)       │ │
│  │             │  │  self-svc)  │  │                     │ │
│  └─────────────┘  └─────────────┘  └─────────────────────┘ │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │
│  │  Helm       │  │  ArgoCD     │  │   OPA Gatekeeper    │ │
│  │  Library    │  │  (GitOps)   │  │   (guardrails)      │ │
│  └─────────────┘  └─────────────┘  └─────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

---

## Golden Path Template

```yaml
# Developer creates new microservice by filling out a form in Backstage
# This scaffolding template creates everything automatically

apiVersion: scaffolder.backstage.io/v1beta3
kind: Template
metadata:
  name: microservice-template
  title: New Python Microservice
spec:
  parameters:
  - title: Service Details
    properties:
      name:
        type: string
        description: Service name (lowercase, hyphens)
      owner:
        type: string
        description: Team name (e.g., payments-team)
      database:
        type: boolean
        default: false
        description: Does this service need a PostgreSQL database?

  steps:
  - id: fetch-template
    action: fetch:template
    input:
      url: ./skeleton
      values:
        name: ${{ parameters.name }}
        owner: ${{ parameters.owner }}
        database: ${{ parameters.database }}

  - id: create-github-repo
    action: publish:github
    input:
      repoUrl: github.com?repo=${{ parameters.name }}&owner=myorg

  - id: register-component
    action: catalog:register
    input:
      repoContentsUrl: ${{ steps.create-github-repo.output.repoContentsUrl }}

# Result:
# ✅ GitHub repo with Dockerfile, tests, CI/CD
# ✅ K8s manifests with Helm chart
# ✅ Monitoring dashboards
# ✅ Registered in Backstage catalog
# ✅ PagerDuty service
# All in < 5 minutes!
```

---

## Key Interview Questions

**Q: What is Platform Engineering and how is it different from DevOps?**

DevOps = breaking silos between Dev and Ops teams, shared responsibility.
Platform Engineering = building products FOR developers. The platform team is a product team.

**Q: What is a "golden path"?**

A pre-approved, well-supported way to accomplish a common task. Not mandatory, but so easy that developers choose it over DIY.

**Q: How do you measure IDP success?**

- Time from "I need a new service" to first deployment (target: < 30 min vs weeks)
- Cognitive load: do developers ask platform team fewer questions?
- Adoption: % of teams using golden paths vs custom approaches
- Developer satisfaction scores (quarterly surveys)
- Platform reliability: < 0.1% impact on developer velocity

**Q: What is Crossplane?**

Infrastructure-as-Code using Kubernetes CRDs. Developers request infrastructure (databases, queues, buckets) through K8s manifests — same tools they already know.

```yaml
# Developer creates a database (self-service, no Terraform knowledge needed)
apiVersion: database.platform.company.com/v1alpha1
kind: PostgreSQLInstance
metadata:
  name: my-service-db
  namespace: my-team
spec:
  size: small     # Platform team defines what "small" means (cost, specs)
  version: "15"
  backup: true
# Platform team's Crossplane Composition creates the actual RDS/CloudSQL instance
```
