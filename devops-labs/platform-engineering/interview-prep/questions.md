# Platform Engineering Interview Questions

## Q1. What is an Internal Developer Platform and what problems does it solve?

An IDP is a self-service layer that abstracts infrastructure complexity from developers.

**Problems solved:**
- Ticket queues for every infra request (days → minutes with self-service)
- Cognitive load (devs don't need to know Terraform, K8s internals, cloud APIs)
- Inconsistency (different teams set up infrastructure differently → ops hell)
- Slow deployments (manual review gates → automated golden paths)
- Knowledge silos (runbooks, dashboards, docs in one place)

**Key insight**: The platform team is a product team. Developers are customers.

---

## Q2. What is Backstage? What are its core features?

```
Backstage: Open-source IDP framework by Spotify (now CNCF)

Core components:
  Software Catalog: Inventory of all services, APIs, teams, resources
                    Every service has catalog-info.yaml → searchable portal
  
  TechDocs: Docs-as-code (Markdown in repo → rendered docs site)
            No more outdated Confluence pages
  
  Software Templates: Scaffolding (golden paths)
                      Form in portal → create repo + CI/CD + monitoring + alerts
  
  Plugins (200+): GitHub, PagerDuty, ArgoCD, Grafana, Kubernetes, etc.

Value: Instead of "where do I find X?", developers have ONE portal for everything.
```

---

## Q3. What is Crossplane and how does it enable platform engineering?

```yaml
# Crossplane = Kubernetes-based infrastructure provisioning
# Turns K8s into a universal control plane for any cloud resource

# Problem:
# Dev needs a database → opens ticket → Ops runs Terraform → 2 weeks
# 
# With Crossplane:
# Dev creates a K8s manifest → Crossplane provisions AWS RDS → 5 minutes

# Key concepts:
# Composition = platform engineers define what "small database" means
# Composite Resource (XR) = abstract resource type (PostgreSQLInstance)
# Managed Resource = actual cloud resource (AWS RDS Instance)
# Provider = plugin for AWS/GCP/Azure

# Advantage over Terraform:
# - K8s-native (same tools, RBAC, GitOps)
# - Continuous reconciliation (drift detection like K8s)
# - Developers use what they know (kubectl/YAML)
# - Platform team controls what's provisioned via Compositions
```

---

## Q4. How do you measure the success of a platform engineering team?

```python
# DORA metrics (DevOps Research and Assessment):
metrics = {
    "deployment_frequency": "> 1/day per team",     # Elite: > multiple/day
    "lead_time_for_changes": "< 1 hour",            # Elite: < 1 hour
    "mttr": "< 1 hour",                             # Elite: < 1 hour
    "change_failure_rate": "< 5%",                  # Elite: 0-15%
}

# Platform-specific metrics:
platform_metrics = {
    # Self-service success
    "golden_path_adoption": "> 80% teams use golden paths",
    "self_service_ratio": "90% infra requests via portal (not tickets)",
    "time_to_first_deploy": "new service → first production deploy < 1 day",
    
    # Developer experience
    "developer_satisfaction": "quarterly survey > 4/5",
    "platform_nps": "net promoter score from developers",
    
    # Platform reliability
    "platform_availability": "99.9% uptime for portal, pipelines, monitoring",
    "p99_provisioning_time": "new database < 10 minutes",
}
```

---

## Q5. What is the difference between a Platform Engineer and a DevOps Engineer?

```
DevOps Engineer (traditionally):
  - Embedded in product teams OR central ops
  - Focuses on CI/CD pipelines, deployments, monitoring for specific services
  - Reactive: fixes problems when they arise
  - Closer to operations

Platform Engineer:
  - Builds reusable tools and platforms for other engineers
  - Product mindset: developers are customers
  - Proactive: builds systems that make the right thing easy
  - Closer to software engineering

Analogy:
  DevOps = A skilled contractor who builds your house
  Platform Engineer = An architect who designs standard house blueprints
                      that many contractors use
```

---

## Q6. What is a "golden path" and how do you encourage adoption?

```
Golden path = The pre-approved, well-supported, documented way to do something
              Low friction for devs. High confidence for ops.

Examples:
  "New microservice" → Backstage template
  "Deploy to production" → GitOps via Argo with standard Helm chart
  "Need a database" → Crossplane PostgreSQLInstance CRD
  "Add monitoring" → ServiceMonitor + pre-built Grafana dashboard

Adoption strategies:
  1. Make it EASIER than DIY (if golden path = 5 min, DIY = 2 days → easy choice)
  2. Document it clearly with copy-paste examples
  3. Have platform team available for help
  4. Gradually deprecate non-golden paths (carrot + stick)
  5. Measure and celebrate adoption
  6. Onboarding: new engineers use golden path in first week
  
  "If it's not adopted, it's not a golden path — it's documentation."
```

---

## Q7. How do you handle security guardrails without being a bottleneck?

```yaml
# Shift-left: automated checks in CI pipeline
# Enforce policies without human approval gates

# Option 1: OPA/Gatekeeper — block non-compliant resources in K8s
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sRequiredLabels
metadata:
  name: require-team-label
spec:
  match:
    kinds: [{apiGroups: ["*"], kinds: ["Deployment"]}]
  parameters:
    labels: ["team", "cost-center"]
# Error at kubectl apply time (not at review time)

# Option 2: Kyverno policies
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-resources
spec:
  rules:
  - name: check-resources
    match:
      any:
      - resources:
          kinds: [Pod]
    validate:
      message: "CPU and memory limits required"
      pattern:
        spec:
          containers:
          - resources:
              limits:
                cpu: "?*"
                memory: "?*"

# Option 3: Automated in CI (GitHub Actions)
# - Run checkov/trivy/kube-score in PR
# - Block merge if CRITICAL findings
# - Developer fixes it locally before asking for review
```

---

## Q8. How do you build an IDP incrementally? Where do you start?

```
Don't try to build everything at once. Start with highest-impact pain points.

Phase 1 (0-3 months): Foundation
  - Service catalog (Backstage)
  - Standardize CI/CD templates (GitHub Actions workflows)
  - Basic self-service: new service scaffold template
  - Unified observability stack

Phase 2 (3-6 months): Self-service
  - Database provisioning (Crossplane or simple forms)
  - Environment promotion workflow
  - Automated DORA metric collection
  - Developer portal search and discovery

Phase 3 (6-12 months): Advanced
  - Full GitOps with ArgoCD
  - Advanced self-service (queues, object storage, etc.)
  - Cost allocation dashboards
  - Tech radar and deprecation tracking

Measurement: Track adoption % and developer satisfaction at each phase.
Adjust based on feedback — platform engineering is iterative.
```

---

## Q9. What is Spotify's BEAT (Backtrace-Enabled Automatic Testing) framework? Oops — tell me about Spotify's Squad Model for platform teams.

```
Spotify's organizational model (inspiration for many platform teams):

Squads = small autonomous teams (5-8 people)
         Each squad owns end-to-end responsibility for a capability

Tribes = collection of squads working in related areas
         (Platform tribe, Growth tribe, etc.)

Chapters = functional communities across squads
           (all frontend devs, all SREs, etc.)

Guilds = informal communities of interest

For Platform Engineering:
  Platform Tribe
    ├── Developer Experience Squad (portal, templates, docs)
    ├── Infrastructure Squad (K8s, Terraform, cloud)
    ├── Observability Squad (monitoring, alerting, logging)
    └── Security Squad (policies, secrets, compliance)

  Each squad owns their piece of the platform as a product.
  Customer = other squads in the company.
```

---

## Q10. How do you avoid the "golden cage" anti-pattern?

```
Golden cage: Platform is so opinionated that teams can't deviate even when needed
             Developers bypass the platform → shadow IT → chaos

Prevention:

1. "Paved road, not mandatory highway"
   - Golden paths reduce friction, don't eliminate choice
   - Teams CAN run custom Terraform, but platform version is easier

2. Escape hatches
   - Document how to bypass the platform
   - Teams own the consequences (no platform SLA for custom infra)

3. Listen to feedback
   - Regular office hours with developers
   - "What can't you do with the platform?"
   - Fix genuine gaps in golden paths

4. Gradual migration
   - Don't force migration; let teams adopt organically
   - Deprecate old ways slowly with ample notice

5. Transparency
   - Open source the platform internally
   - Any team can contribute improvements
   - Share platform roadmap
```

---

## Q11. What is a Service Scorecard?

```yaml
# Service Scorecard: automated quality measurement for every service
# Shown in Backstage catalog → "this service scores 73/100"

# Common scorecard dimensions:

production_readiness_scorecard:
  documentation:
    - has_runbook: 10 points
    - has_architecture_diagram: 5 points
    - has_readme: 5 points
  
  observability:
    - has_prometheus_metrics: 10 points
    - has_alerts_configured: 10 points
    - has_grafana_dashboard: 5 points
    - has_distributed_tracing: 5 points
  
  reliability:
    - has_health_endpoint: 10 points
    - has_pdb: 5 points
    - has_hpa: 5 points
    - deployment_frequency_gt_1_per_week: 10 points
  
  security:
    - not_running_as_root: 10 points
    - has_network_policy: 5 points
    - dependencies_up_to_date: 5 points

# Teams with low scores get:
# - Automatic issue created in JIRA/GitHub
# - Visibility in platform portal
# - Not blocking, but incentivized to improve
```

---

## Q12. How does Platform Engineering relate to SRE?

```
They're complementary, not competing:

SRE focuses on:
  - Reliability of production services
  - SLOs, error budgets, incident response
  - Embedded in product teams
  - "Is our service reliable?"

Platform Engineering focuses on:
  - Developer productivity
  - Self-service infrastructure
  - Reducing toil across all teams
  - "Can all teams ship reliably?"

Overlap:
  - Both care about reducing operational toil
  - SREs become platform customers (need good CI/CD, monitoring)
  - Platform team builds tools that help SREs (dashboards, runbook automation)
  - Platform team has its own SLOs (portal availability, pipeline reliability)

At many companies:
  - Small companies: SRE and Platform Eng are the same team
  - Large companies: separate but closely collaborative
```

---

## Q13. What is Tech Radar and how does a platform team use it?

```
Tech Radar (popularized by ThoughtWorks):
  Visualizes technology choices in 4 quadrants × 4 rings

Quadrants: Languages/Frameworks, Tools, Platforms, Techniques
Rings:     Adopt → Trial → Assess → Hold

Platform team uses it to:
  1. Signal which technologies are approved/not approved
  2. Guide teams away from deprecated tech (Hold ring)
  3. Promote new golden path tools (move to Adopt)
  4. Reduce tech sprawl (too many DB types, too many CI systems)

Example:
  Adopt:  Kubernetes, GitHub Actions, Terraform, Python 3.12
  Trial:  KEDA, Cilium, Crossplane
  Assess: Dagger (CI/CD), Kairos (immutable K8s)
  Hold:   Jenkins, Ansible for K8s config, Serverless Framework

Updated quarterly. Published in Backstage portal.
Any team can propose changes via PR.
```

---

## Q14. How do you handle multi-tenancy in a shared platform?

```yaml
# Multi-tenancy: multiple teams on one platform with isolation

# Kubernetes namespace per team
# + ResourceQuota (CPU/memory limits)
# + NetworkPolicies (teams can't reach each other's services)
# + RBAC (team can only manage their namespace)
# + LimitRange (enforce resource requests on all pods)

# Tenant provisioning via platform:
# Team fills form in Backstage → automation creates:

apiVersion: v1
kind: Namespace
metadata:
  name: team-payments
  labels:
    team: payments
    cost-center: fin-001
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: payments-quota
  namespace: team-payments
spec:
  hard:
    requests.cpu: "20"
    requests.memory: 40Gi
    limits.cpu: "40"
    limits.memory: 80Gi
    pods: "100"
---
# Also creates:
# - ServiceAccount for CI/CD
# - RBAC for team members
# - Monitoring namespace in Grafana
# - Alert routing to team's Slack channel
```

---

## Q15. A team bypasses the platform and runs their own infrastructure. What do you do?

```
Don't fight it — understand it.

Step 1: LISTEN — why did they bypass?
  "The platform didn't support our use case"
  "Platform was too slow / complex"
  "We needed X feature that wasn't available"

Step 2: DOCUMENT the gap
  - Is this a missing feature in the platform?
  - Is there a security/compliance concern with their approach?

Step 3: DECIDE
  A. Valid use case → add to platform, offer migration path
  B. Security concern → work with them on a compliant approach
  C. Preference → make platform SO easy they choose it next time
  D. One-off → document it, accept it, move on

What NOT to do:
  ❌ Force them to use the platform anyway
  ❌ Block their deployment
  ❌ Ignore it (it grows into tech debt)

Platform engineering philosophy:
  "The platform should be a magnet, not a fence."
```
