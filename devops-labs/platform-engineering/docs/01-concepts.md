# Platform Engineering Core Concepts

## What is Platform Engineering?

Platform Engineering is the discipline of designing and building **self-service internal developer platforms (IDPs)** that empower software engineering teams to ship faster with fewer cognitive bottlenecks.

```
Traditional DevOps model:
  Dev → "Can you set up a database for me?" → Ops → (2 weeks later) → DB ready
  
Platform Engineering model:
  Dev → fills form in portal → (5 minutes later) → DB ready, monitoring configured,
                                                     runbook created, backups enabled
```

---

## The Platform as a Product Mindset

```
Traditional IT: "How can we prevent things from breaking?"
DevOps:         "How can we deploy faster while staying reliable?"
Platform Eng:   "How can we make it easy for developers to do the right thing?"

The platform team builds:
  - Golden paths (pre-approved, supported ways to do common tasks)
  - Self-service infrastructure
  - Developer portal (discoverability)
  - Guardrails (not gatekeeping)

The platform team treats developers as customers:
  - Gather requirements (what do devs actually need?)
  - Measure adoption (are teams using the golden paths?)
  - Iterate based on feedback
  - SLOs for the platform itself
```

---

## Internal Developer Platform (IDP) Components

```
┌─────────────────────────────────────────────────────────────┐
│                  Internal Developer Platform                 │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │              Developer Portal (Backstage)             │   │
│  │  Service catalog | Docs | Tech radar | Scorecards    │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │   Self-Service│  │  Paved Roads │  │   Guardrails     │  │
│  │   Infra       │  │  (Templates) │  │   (Policies)     │  │
│  │  (Crossplane) │  │  (Backstage) │  │   (OPA/Kyverno)  │  │
│  └──────────────┘  └──────────────┘  └──────────────────┘  │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │            Deployment Platform                        │   │
│  │   GitOps (ArgoCD/Flux) | Helm Library | Kustomize    │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │            Observability Platform                     │   │
│  │   Prometheus | Grafana | Loki | Tempo | Alertmanager │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

---

## Backstage — The Developer Portal

```
Backstage (by Spotify) is an open-source IDP framework.

Core features:
  Software catalog  — inventory of all services, APIs, teams, resources
  TechDocs          — documentation-as-code (Markdown → searchable portal)
  Software templates — golden paths (new service in 5 min)
  Plugins           — extend with 200+ community plugins

catalog-info.yaml (every service has one):

apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: payment-service
  description: Handles payment processing
  annotations:
    github.com/project-slug: myorg/payment-service
    backstage.io/techdocs-ref: dir:.
    pagerduty.com/service-id: P123ABC
  tags:
    - payments
    - critical
    - java
  links:
    - url: https://grafana.company.com/d/payment-svc
      title: Grafana Dashboard
    - url: https://wiki.company.com/runbooks/payment
      title: Runbook
spec:
  type: service
  lifecycle: production
  owner: payments-team
  system: payment-platform
  dependsOn:
    - component:database-cluster
    - component:fraud-detection-service
  providesApis:
    - payment-api-v2
```

---

## Crossplane — Infrastructure Self-Service

```
Crossplane turns Kubernetes into a universal control plane.
Developers provision any cloud resource using K8s manifests.

Without Crossplane:
  Dev → tickets Ops → Ops writes Terraform → 2 weeks

With Crossplane:
  Dev → applies K8s manifest → Crossplane provisions cloud resource → 5 minutes

# Developer requests a database (no Terraform knowledge needed):
apiVersion: database.example.com/v1alpha1
kind: PostgreSQLInstance
metadata:
  name: my-service-db
  namespace: my-team
spec:
  size: small          # Platform defines: db.t3.micro, 20GB, single-AZ
  version: "15"
  backup: true
  # That's it! Platform handles: VPC, subnet, security group, backup policy

# Platform engineer defines what "small" means via Composition:
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: postgresql-small
spec:
  compositeTypeRef:
    apiVersion: database.example.com/v1alpha1
    kind: PostgreSQLInstance
  resources:
  - name: rds-instance
    base:
      apiVersion: rds.aws.upbound.io/v1beta1
      kind: Instance
      spec:
        forProvider:
          instanceClass: db.t3.micro
          allocatedStorage: 20
          multiAz: false
          # ... all the Terraform-equivalent config
```

---

## Golden Paths vs Paved Roads

```
Golden Path = the recommended way to do something
              Well-supported, documented, monitored
              Not mandatory — teams can deviate (with extra friction)

Paved Road   = The easiest path is also the right path
              If it's easier to use the platform correctly than to DIY,
              most teams will choose the platform

Example:
  "You need a PostgreSQL database"
  
  Option A (bypass platform): Set up your own EC2 Postgres → 2 days + ongoing maintenance
  Option B (golden path): Fill out Backstage form → 5 minutes, fully managed
  
  When Option B is faster AND better, teams choose it naturally.
  That's a paved road.
```

---

## Platform Engineering Metrics

```python
# Measure platform success:

metrics = {
    # Developer productivity
    "time_to_production": "PR merged → production (target: < 30 min)",
    "deployment_frequency": "deploys per team per day (target: > 3/day)",
    "lead_time_for_changes": "commit to production (target: < 1 hour)",
    
    # Platform adoption
    "golden_path_adoption_pct": "% teams using golden path vs DIY (target: > 80%)",
    "self_service_ratio": "infra requests filled by self-service vs tickets",
    "portal_dau": "daily active users in developer portal",
    
    # Platform reliability
    "platform_uptime": "is the platform itself available? (target: 99.9%)",
    "p99_provisioning_time": "time to provision new service via portal",
    
    # Cognitive load
    "developer_satisfaction": "quarterly survey (target: > 4/5)",
    "toil_hours_per_week": "time developers spend on infrastructure (target: < 1h/week)",
    "oncall_pages_for_infra": "pages from infra issues vs app issues",
}
```

---

## Platform Engineering Team Structure

```
Platform Engineering team ≠ Ops team

Platform team responsibilities:
  - Design and build the IDP
  - Define golden paths
  - Maintain the deployment platform
  - Manage shared infrastructure (cluster, logging, monitoring)
  - Evangelize and educate
  
What platform team does NOT do:
  - Review every deployment manually
  - Be the gatekeeper for every infra change
  - Build features in product teams' code

Team size: 1 platform engineer per 8-12 product engineers (at scale)
Minimum viable team: 3-4 engineers to build and maintain IDP

Career path:
  SRE → Platform Engineer → Staff Platform Engineer → Principal Platform Engineer
  DevOps Engineer → Platform Engineer (common transition)
```
