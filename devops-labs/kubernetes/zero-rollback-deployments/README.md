# Zero-Rollback Deployments

> **How production rollbacks were reduced by 70% at Grhombus / TPG Tax Pro.**
> The remaining 30% were intentional hotfixes, not emergency rollbacks.

---

## The Core Insight

```
Rollback = production failure detected too late to prevent.

Prevention layers:
  Layer 1: Catch 95% of bugs in pre-production (gates)
  Layer 2: Expose remaining bugs to 1% of traffic first (canary)
  Layer 3: Decouple deployment from release (feature flags)
  Layer 4: Auto-rollback in < 5 min if health degrades (health gates)
  Layer 5: See everything the moment it ships (observability-first)
```

---

## Five-Strategy Framework

```
┌─────────────────────────────────────────────────────────────┐
│              ZERO-ROLLBACK DEPLOYMENT SYSTEM                 │
│                                                              │
│  ① FEATURE FLAGS      ← Decouple deploy from release        │
│     Code ships, feature is off. Toggle without deploy.       │
│                                                              │
│  ② PRE-PROD GATES     ← Catch 95% before production         │
│     SAST → DAST → Integration → Perf → Chaos (staging)      │
│                                                              │
│  ③ PROGRESSIVE DELIVERY ← Never 0% → 100% instantly        │
│     Canary: 1% → 10% → 25% → 50% → 100%                    │
│     Blue/Green: atomic traffic switch, instant rollback      │
│                                                              │
│  ④ HEALTH GATES       ← Auto-rollback in < 5 min           │
│     ArgoCD analysis: error rate + latency post-deploy        │
│                                                              │
│  ⑤ OBSERVABILITY FIRST ← See it the moment it ships        │
│     Deploy only if new version has metrics + tracing         │
└─────────────────────────────────────────────────────────────┘
```

---

## Folder Structure

```
zero-rollback-deployments/
├── README.md
├── progressive-delivery/
│   ├── blue-green/
│   │   ├── manifests.yaml            ← Blue/green K8s setup
│   │   ├── traffic-switch.sh         ← Atomic switch script
│   │   └── cicd-pipeline.yml         ← GitHub Actions blue/green
│   ├── canary/
│   │   ├── canary-manifests.yaml     ← K8s canary (Service + weighted pods)
│   │   └── canary-pipeline.yml       ← Progressive promotion pipeline
│   └── argo-rollouts/
│       ├── rollout-canary.yaml       ← Full Argo Rollouts strategy
│       ├── analysis-template.yaml   ← Prometheus health gates
│       └── install.sh               ← Install Argo Rollouts
├── feature-flags/
│   ├── unleash/
│   │   ├── docker-compose.yml        ← Self-hosted Unleash stack
│   │   └── sdk-examples.py           ← Python/Node/Java SDK patterns
│   └── configmap-flags/
│       ├── feature-flags.yaml        ← K8s ConfigMap approach
│       └── toggle.sh                 ← Toggle without deployment
├── pre-prod-gates/
│   ├── github-actions/
│   │   ├── full-gate-pipeline.yml    ← All gates in sequence
│   │   ├── sast.yml                  ← CodeQL + Semgrep
│   │   ├── dast.yml                  ← OWASP ZAP
│   │   └── performance.yml           ← k6 baseline gate
│   ├── k6/
│   │   └── performance-baseline.js   ← k6 load test script
│   └── chaos/
│       └── staging-chaos.yaml        ← LitmusChaos in staging
├── health-gates/
│   ├── argocd-hooks/
│   │   ├── analysis-template.yaml   ← Prometheus-based auto-analysis
│   │   ├── rollout-with-analysis.yaml
│   │   └── post-sync-check.sh       ← Hook: runs post-deploy
│   ├── scripts/
│   │   └── deployment-health-gate.sh ← Blocks deploy if metrics degrade
│   └── prometheus/
│       └── deployment-alerts.yaml    ← Alerts scoped to deploy window
└── observability-first/
    ├── instrumentation/
    │   ├── python-metrics.py         ← Flask/FastAPI instrumentation
    │   ├── nodejs-metrics.js         ← Express instrumentation
    │   └── pre-deploy-checklist.sh   ← Verify metrics exist before deploy
    └── dashboards/
        └── deployment-health.json    ← "Is this deploy healthy?" dashboard
```

---

## The Numbers

| Metric | Before | After | Method |
|--------|--------|-------|--------|
| Emergency rollbacks/month | ~8 | ~2.4 | Progressive delivery + health gates |
| MTTD (deploy → detect issue) | 25 min | 3 min | Health gates + observability |
| Users hit by bad deploy | ~15% | ~1% | Canary at 1% first |
| Deploys/day | 2 | 12 | Feature flags remove deploy fear |
| Post-deploy incidents | 3/week | 0.5/week | Pre-prod gates |

---

## Quick Start

```bash
# 1. Install Argo Rollouts (progressive delivery engine)
bash progressive-delivery/argo-rollouts/install.sh

# 2. Apply the canary rollout for your service
kubectl apply -f progressive-delivery/argo-rollouts/rollout-canary.yaml
kubectl apply -f progressive-delivery/argo-rollouts/analysis-template.yaml

# 3. Deploy with health gates (automatic — watch it promote itself)
kubectl argo rollouts set image my-rollout app=myapp:v2
kubectl argo rollouts get rollout my-rollout --watch

# 4. Add feature flag SDK to your app
# See feature-flags/unleash/sdk-examples.py

# 5. Add pre-prod gates to your CI
# Copy pre-prod-gates/github-actions/full-gate-pipeline.yml to .github/workflows/
```
