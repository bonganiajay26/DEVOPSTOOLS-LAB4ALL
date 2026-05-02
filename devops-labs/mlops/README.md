# MLOps

> **Machine Learning Operations — automate the full ML lifecycle from training to production serving.**

---

## Quick Navigation

| Section | Contents |
|---------|----------|
| [docs/01-concepts.md](docs/01-concepts.md) | ML pipelines, feature stores, model registry |
| [docs/02-serving.md](docs/02-serving.md) | Model serving patterns, A/B testing, monitoring |
| [examples/](examples/) | MLflow, KFServing, Kubeflow examples |
| [labs/](labs/) | End-to-end ML pipeline lab |
| [interview-prep/questions.md](interview-prep/questions.md) | 15 interview Q&A |

---

## The MLOps Problem

```
Traditional ML:
  Notebook → "It works on my laptop!" → Manual deploy → Forgotten

MLOps:
  Automated pipeline:
  Data → Feature Engineering → Train → Validate → Package → Deploy → Monitor → Retrain

Key challenges:
  1. Reproducibility: same code + data + env = same model
  2. Versioning: track code, data, AND model versions
  3. Deployment: model serving at scale
  4. Monitoring: data drift, model drift, performance degradation
  5. Governance: who trained what, on what data, with what result
```

---

## MLOps Maturity Levels

```
Level 0 — Manual
  Jupyter notebooks, manual deploy, no monitoring
  Use when: prototyping, POC

Level 1 — ML Pipeline Automation
  Automated training pipeline
  Model registry, basic monitoring
  Use when: >1 model in production

Level 2 — CI/CD for ML
  Automated pipeline deployment
  A/B testing, drift detection
  Feature store
  Use when: frequent retraining, team > 3 ML engineers
```
