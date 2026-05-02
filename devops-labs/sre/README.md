# Site Reliability Engineering (SRE)

> **Applying software engineering to operations problems. SLOs, error budgets, toil elimination.**

---

## Quick Navigation

| Section | Contents |
|---------|----------|
| [docs/01-slo-sla-sli.md](docs/01-slo-sla-sli.md) | SLIs, SLOs, SLAs, error budgets |
| [docs/02-incident-management.md](docs/02-incident-management.md) | On-call, runbooks, post-mortems |
| [examples/](examples/) | SLO configs, alerting rules, runbooks |
| [interview-prep/questions.md](interview-prep/questions.md) | 15 interview Q&A |

---

## The SRE Mental Model

```
Traditional Ops: "Don't let anything break"
SRE:             "Things will break. Define how much failure is acceptable,
                  invest engineering effort to reduce it, balance with feature velocity."

Key insight:
  100% availability = impossible AND undesirable
  → Every minute of maintenance work eliminates feature velocity
  → Error budget = agreed upon acceptable downtime
  → If you haven't used your error budget → you're not moving fast enough
```
